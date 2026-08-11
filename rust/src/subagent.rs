//! --subagent panel mode: speak Claude Code's subagentStatusLine protocol —
//! one {"id","content"} JSON line per agent-panel row. Ported faithfully from
//! upstream statusline.sh's subagent branch (scrub, sidecar role recovery,
//! subseg_name/model/ctx/elapsed, json_escape) so rows are byte-identical.
use crate::config::{msys_to_win, Config};
use crate::json::{self, Json};
use crate::render;

const R_BOLD: &str = "\x1b[1m";
const R_NORM: &str = "\x1b[22m";

/// Drop C0, DEL, and C1 control characters — both the security scrub (crafted
/// labels can't smuggle terminal escapes) and the framing guard upstream does
/// in jq before splitting fields.
fn scrub(s: &str) -> String {
    s.chars()
        .filter(|&c| {
            let u = c as u32;
            !(u < 0x20 || u == 0x7f || (0x80..=0x9f).contains(&u))
        })
        .collect()
}

/// jq `tostring` of a scalar field (strings pass through, numbers render
/// integer-if-whole), then scrubbed.
fn field(t: &Json, key: &str) -> String {
    match t.get(key) {
        Some(Json::Str(s)) => scrub(s),
        Some(Json::Num(n)) => scrub(&crate::fmt_num(*n)),
        Some(Json::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

/// JSON-string escape for the output protocol: escapes \ " and the JSON
/// control shorthands, maps ESC to backslash-u001b (ANSI colors survive the
/// round-trip), drops any other control character.
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\x1b' => out.push_str("\\u001b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c == '\x7f' => {}
            c => out.push(c),
        }
    }
    out
}

/// Resolved model ID → short display name ("claude-haiku-4-5-20251001" →
/// "Haiku 4.5"). Unrecognized IDs pass through verbatim.
fn model_short(s: &str) -> String {
    let Some(rest) = s.strip_prefix("claude-") else {
        return s.to_string();
    };
    // strip a trailing -YYYYMMDD date stamp
    let rest = match rest.rsplit_once('-') {
        Some((head, tail)) if tail.len() == 8 && tail.bytes().all(|b| b.is_ascii_digit()) => head,
        _ => rest,
    };
    let (fam, ver) = match rest.split_once('-') {
        Some((f, v)) => (f, v),
        None => (rest, ""),
    };
    if ver.is_empty() || !ver.bytes().all(|b| b.is_ascii_digit() || b == b'-') {
        return s.to_string();
    }
    let fam = match fam {
        "fable" => "Fable",
        "opus" => "Opus",
        "sonnet" => "Sonnet",
        "haiku" => "Haiku",
        _ => return s.to_string(),
    };
    format!("{fam} {}", ver.replace('-', "."))
}

/// Strict startTime parser: pure-digit epoch seconds, pure-digit epoch
/// milliseconds (13+ digits), or canonical valid UTC ISO. Anything else hides
/// the elapsed segment.
fn sub_epoch(t: &str) -> Option<i64> {
    if t.is_empty() {
        return None;
    }
    if t.bytes().all(|b| b.is_ascii_digit()) {
        let v: i64 = t.parse().ok()?;
        return Some(if t.len() >= 13 { v / 1000 } else { v });
    }
    render::iso_epoch_strict(t)
}

fn valid_token(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// Recover the agent role from the local task metadata sidecar
/// (<transcript>/subagents/agent-<id>.meta.json, first line, "agentType").
fn subagent_role(transcript: &str, id: &str) -> Option<String> {
    if !valid_token(id) {
        return None;
    }
    let base = transcript.strip_suffix(".jsonl")?;
    let path = format!("{base}/subagents/agent-{id}.meta.json").replace('\\', "/");
    let path = msys_to_win(&path);
    let text = std::fs::read_to_string(&path).ok()?;
    let line = text.lines().next().unwrap_or("");
    let role = line.split("\"agentType\":\"").nth(1)?.split('"').next()?;
    if valid_token(role) {
        Some(role.to_string())
    } else {
        None
    }
}

/// fmt_duration with seconds (upstream's `$2=1` variant).
fn fmt_duration_s(ms: i64) -> String {
    let s = ms / 1000;
    let h = s / 3600;
    let m = (s % 3600) / 60;
    let sec = s % 60;
    if h > 0 {
        format!("{h}h{m:02}m{sec:02}s")
    } else if m > 0 {
        format!("{m}m{sec:02}s")
    } else {
        format!("{s}s")
    }
}

struct Task {
    id: String,
    name: String,
    label: String,
    desc: String,
    typ: String,
    status: String,
    start: String,
    model: String,
    cws: String,
    tok: String,
    role: String,
}

struct SubCtx<'a> {
    cfg: &'a Config,
    now: i64,
    fg_text: String,
    fg_dim: String,
    fg_ok: String,
    fg_warn: String,
    fg_hot: String,
    fg_sub_text: String,
    fg_sub_ok: String,
    fg_sub_hot: String,
    fg_sub_dim: String,
}

impl<'a> SubCtx<'a> {
    fn pct_fg(&self, p: i64) -> &str {
        if p >= self.cfg.hot_pct {
            &self.fg_hot
        } else if p >= self.cfg.warn_pct {
            &self.fg_warn
        } else {
            &self.fg_ok
        }
    }

    fn push(&self, segs: &mut Vec<render::Seg>, bgc: &str, txt: String) {
        segs.push(render::Seg {
            bg: bgc.to_string(),
            txt,
            len: 0, // panel rows never wrap; the width scan is skipped upstream too
        });
    }

    fn or<'b>(&self, v: &'b str, fallback: &'b str) -> &'b str {
        if v.is_empty() {
            fallback
        } else {
            v
        }
    }

    fn subseg_name(&self, t: &Task, segs: &mut Vec<render::Seg>) {
        let cfg = self.cfg;
        let mut identity = if !t.name.is_empty() {
            t.name.clone()
        } else {
            t.role.clone()
        };
        if !t.name.is_empty() && !t.role.is_empty() && t.name != t.role {
            identity = format!("{} ({})", t.name, t.role);
        }
        let detail = if !t.label.is_empty() { &t.label } else { &t.desc };
        let label = if !identity.is_empty() {
            let mut l = identity;
            if !detail.is_empty() && *detail != t.name && *detail != t.role {
                l = format!("{l} \u{b7} {detail}");
            }
            l
        } else if !detail.is_empty() {
            detail.clone()
        } else {
            t.typ.clone()
        };
        if label.is_empty() {
            return;
        }
        // The status inks are the name pill's own, when the theme published a
        // set for the ground it paints; empty falls back to the main palette.
        let col = match t.status.as_str() {
            "running" | "in_progress" | "active" => &self.fg_sub_text,
            "completed" | "success" | "done" => &self.fg_sub_ok,
            "failed" | "error" | "cancelled" => &self.fg_sub_hot,
            _ => &self.fg_sub_dim, // incl. missing → unknown
        };
        self.push(
            segs,
            self.or(&cfg.bg_sub_name, &cfg.bg_dir),
            format!(
                "{R_BOLD}{col} {} {R_NORM}",
                render::trunc(&label, cfg.name_max)
            ),
        );
    }

    fn subseg_model(&self, t: &Task, segs: &mut Vec<render::Seg>) {
        if t.model.is_empty() {
            return;
        }
        self.push(
            segs,
            self.or(&self.cfg.bg_sub_model, &self.cfg.bg_model),
            format!(
                "{R_BOLD}{} \u{25C6} {} {R_NORM}",
                self.fg_text,
                model_short(&t.model)
            ),
        );
    }

    fn subseg_ctx(&self, t: &Task, segs: &mut Vec<render::Seg>) {
        let cfg = self.cfg;
        let tokint = t.tok.split('.').next().unwrap_or("");
        // 16 digits keeps *100 inside signed 64-bit arithmetic (upstream guard).
        if tokint.is_empty() || !tokint.bytes().all(|b| b.is_ascii_digit()) || tokint.len() > 16 {
            return;
        }
        let tok: i64 = tokint.parse().unwrap_or(0);
        let tok_s = render::fmt_tok(tok);
        let cws: i64 = if t.cws.len() <= 16 && !t.cws.is_empty() && t.cws.bytes().all(|b| b.is_ascii_digit()) {
            t.cws.parse().unwrap_or(0)
        } else {
            0
        };
        let bgc = self.or(&cfg.bg_sub_ctx, &cfg.bg_ctx);
        if cws > 0 {
            let mut ci = tok * 100 / cws;
            if ci > 100 {
                ci = 100;
            }
            let bar = render::make_bar(ci, cfg.bar_width, &cfg.bar_fill, &cfg.bar_empty);
            self.push(
                segs,
                bgc,
                format!(
                    "{} {} {} {}% {}{} ",
                    self.pct_fg(ci),
                    cfg.ctx_glyph,
                    bar,
                    ci,
                    self.fg_dim,
                    tok_s
                ),
            );
        } else {
            self.push(
                segs,
                bgc,
                format!("{} {} {} ", self.fg_dim, cfg.ctx_glyph, tok_s),
            );
        }
    }

    fn subseg_elapsed(&self, t: &Task, segs: &mut Vec<render::Seg>) {
        if t.start.is_empty() {
            return;
        }
        let Some(ep) = sub_epoch(&t.start) else {
            return;
        };
        let diff = self.now - ep;
        if diff < 0 {
            return;
        }
        self.push(
            segs,
            self.or(&self.cfg.bg_sub_elapsed, &self.cfg.bg_duration),
            format!("{} \u{29D6} {} ", self.fg_text, fmt_duration_s(diff * 1000)),
        );
    }
}

/// `${VL_FG_SUB_X:-$VL_FG_X}` — an unset panel ink falls back to the main one.
fn fallback<'a>(v: &'a str, main: &'a str) -> &'a str {
    if v.is_empty() {
        main
    } else {
        v
    }
}

/// Render the panel rows for the (possibly concatenated) stdin payload.
/// Returns the full stdout text ("" when there is nothing to draw).
pub fn run(input: &str, cfg: &Config, now: i64) -> String {
    // Claude Code can deliver several concatenated {columns,tasks} documents in
    // one read; each is a full snapshot, so only the newest is current.
    let docs = json::parse_all(input);
    let Some(doc) = docs.last() else {
        return String::new();
    };
    let transcript = doc
        .get("transcript_path")
        .and_then(|v| v.as_str())
        .map(scrub)
        .unwrap_or_default();
    let Some(Json::Arr(tasks)) = doc.get("tasks") else {
        return String::new();
    };
    let ctx = SubCtx {
        cfg,
        now,
        fg_text: render::fg(&cfg.fg_text),
        fg_dim: render::fg(&cfg.fg_dim),
        fg_ok: render::fg(&cfg.fg_ok),
        fg_warn: render::fg(&cfg.fg_warn),
        fg_hot: render::fg(&cfg.fg_hot),
        fg_sub_text: render::fg(fallback(&cfg.fg_sub_text, &cfg.fg_text)),
        fg_sub_ok: render::fg(fallback(&cfg.fg_sub_ok, &cfg.fg_ok)),
        fg_sub_hot: render::fg(fallback(&cfg.fg_sub_hot, &cfg.fg_hot)),
        fg_sub_dim: render::fg(fallback(&cfg.fg_sub_dim, &cfg.fg_dim)),
    };
    let mut out = String::new();
    for tj in tasks {
        let mut t = Task {
            id: field(tj, "id"),
            name: field(tj, "name"),
            label: field(tj, "label"),
            desc: field(tj, "description"),
            typ: field(tj, "type"),
            status: field(tj, "status"),
            start: field(tj, "startTime"),
            model: field(tj, "model"),
            cws: field(tj, "contextWindowSize"),
            tok: field(tj, "tokenCount"),
            role: String::new(),
        };
        if t.id.is_empty() {
            continue;
        }
        if t.typ == "local_agent" {
            if let Some(role) = subagent_role(&transcript, &t.id) {
                t.role = role;
            }
        }
        let mut segs: Vec<render::Seg> = Vec::new();
        for name in cfg.sub_segments.split_whitespace() {
            match name {
                "name" => ctx.subseg_name(&t, &mut segs),
                "model" => ctx.subseg_model(&t, &mut segs),
                "ctx" => ctx.subseg_ctx(&t, &mut segs),
                "elapsed" => ctx.subseg_elapsed(&t, &mut segs),
                _ => {}
            }
        }
        if segs.is_empty() {
            continue;
        }
        let row = render::print_range(cfg, &segs, 0, segs.len() - 1);
        out.push_str(&format!(
            "{{\"id\":\"{}\",\"content\":\"{}\"}}\n",
            json_escape(&t.id),
            json_escape(&row)
        ));
    }
    out
}
