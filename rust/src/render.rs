//! Segment building + layout, ported faithfully from upstream statusline.sh so
//! output is byte-identical to the bash renderer.
use crate::config::Config;
use crate::git::GitInfo;
use crate::Payload;

const R: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const NORM: &str = "\x1b[22m";

struct Seg {
    bg: String,
    txt: String,
    len: usize,
}

fn color(spec: &str, fgbg: u8) -> String {
    if spec.is_empty() {
        return String::new();
    }
    if spec.contains(',') {
        let mut it = spec.split(',');
        let r = it.next().unwrap_or("0");
        let g = it.next().unwrap_or("0");
        let b = it.next().unwrap_or("0");
        format!("\x1b[{};2;{};{};{}m", fgbg, r, g, b)
    } else {
        format!("\x1b[{};5;{}m", fgbg, spec)
    }
}
fn fg(spec: &str) -> String {
    color(spec, 38)
}
fn bg(spec: &str) -> String {
    color(spec, 48)
}

/// Visible width: char count with ANSI escape sequences (ESC…m) stripped.
fn seg_len(s: &str) -> usize {
    let mut n = 0usize;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for d in chars.by_ref() {
                if d == 'm' {
                    break;
                }
            }
        } else {
            n += 1;
        }
    }
    n
}

fn make_bar(pct: i64, width: i64, fill: &str, empty: &str) -> String {
    let mut filled = (pct * width + 50) / 100;
    if filled > width {
        filled = width;
    }
    if filled < 0 {
        filled = 0;
    }
    let mut s = String::new();
    for _ in 0..filled {
        s.push_str(fill);
    }
    for _ in filled..width {
        s.push_str(empty);
    }
    s
}

/// 1234 → 1.2k · 1234567 → 1.2M (integer math only), matching upstream fmt_tok.
fn fmt_tok(n: i64) -> String {
    if n >= 1_000_000 {
        format!("{}.{}M", n / 1_000_000, (n % 1_000_000) / 100_000)
    } else if n >= 1000 {
        format!("{}.{}k", n / 1000, (n % 1000) / 100)
    } else {
        format!("{}", n)
    }
}

fn fmt_duration(ms: i64) -> String {
    let s = ms / 1000;
    let h = s / 3600;
    let m = (s % 3600) / 60;
    if h > 0 {
        format!("{}h{:02}m", h, m)
    } else if m > 0 {
        format!("{}m", m)
    } else {
        format!("{}s", s)
    }
}

/// Middle-truncate to `max` visible chars with … ; max<=0 → unchanged.
fn trunc(s: &str, max: i64) -> String {
    if max <= 0 {
        return s.to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    let len = chars.len() as i64;
    if len <= max {
        return s.to_string();
    }
    if max < 3 {
        return chars[..max as usize].iter().collect();
    }
    let head = (max - 1) / 2;
    let tail = max - 1 - head;
    let start = len - tail;
    let h: String = chars[..head as usize].iter().collect();
    let t: String = chars[start as usize..].iter().collect();
    format!("{h}\u{2026}{t}")
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn to_epoch(t: &str) -> Option<i64> {
    let t = t.trim();
    if t.is_empty() {
        return None;
    }
    if t.contains('T') {
        let b = t.as_bytes();
        if b.len() < 19 {
            return None;
        }
        let g = |a: usize, z: usize| std::str::from_utf8(&b[a..z]).ok()?.parse::<i64>().ok();
        let y = g(0, 4)?;
        let mo = g(5, 7)?;
        let d = g(8, 10)?;
        let h = g(11, 13)?;
        let mi = g(14, 16)?;
        let s = g(17, 19)?;
        Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s)
    } else {
        t.split('.').next().unwrap_or(t).parse::<i64>().ok()
    }
}

fn fmt_countdown(reset: &str, now: i64) -> String {
    let rst = match to_epoch(reset) {
        Some(v) => v,
        None => return String::new(),
    };
    let diff = rst - now;
    if diff <= 0 {
        return "now".into();
    }
    let d = diff / 86400;
    let h = (diff % 86400) / 3600;
    let m = (diff % 3600) / 60;
    if d > 0 {
        format!("{}d{:02}h", d, h)
    } else if h > 0 {
        format!("{}h{:02}m", h, m)
    } else {
        format!("{}m", m)
    }
}

fn round_pct(v: f64) -> i64 {
    v.round() as i64
}

struct Ctx<'a> {
    cfg: &'a Config,
    p: &'a Payload,
    git: &'a GitInfo,
    home: &'a str,
    hour: u32,
    min: u32,
    sec: u32,
    now_epoch: i64,
    fg_text: String,
    fg_dim: String,
    fg_ok: String,
    fg_warn: String,
    fg_hot: String,
}

impl<'a> Ctx<'a> {
    fn pct_fg(&self, p: i64) -> String {
        if p >= self.cfg.hot_pct {
            self.fg_hot.clone()
        } else if p >= self.cfg.warn_pct {
            self.fg_warn.clone()
        } else {
            self.fg_ok.clone()
        }
    }

    fn build(&self, list: &str) -> Vec<Seg> {
        let mut segs = Vec::new();
        for name in list.split_whitespace() {
            self.seg(name, &mut segs);
        }
        segs
    }

    fn push(&self, segs: &mut Vec<Seg>, bgc: &str, txt: String) {
        let len = seg_len(&txt);
        segs.push(Seg {
            bg: bgc.to_string(),
            txt,
            len,
        });
    }

    fn seg(&self, name: &str, segs: &mut Vec<Seg>) {
        let cfg = self.cfg;
        let p = self.p;
        match name {
            "project" => {
                if self.git.root.is_empty() {
                    return;
                }
                self.push(
                    segs,
                    &cfg.bg_dir,
                    format!(
                        "{BOLD}{} \u{2B22} {} {NORM}",
                        self.fg_text,
                        trunc(&self.git.root, cfg.name_max)
                    ),
                );
            }
            "dir" => {
                if p.cwd.is_empty() {
                    return;
                }
                let short = if !self.home.is_empty() && p.cwd.starts_with(self.home) {
                    format!("~{}", &p.cwd[self.home.len()..])
                } else {
                    p.cwd.clone()
                };
                // Split like bash `set -- $short` with IFS=/: a leading '/' yields
                // a leading empty field, so "/a/b/c/d" counts as 5 fields (and the
                // rebuilt "$1/$2/…/$last" keeps the leading slash). Don't drop empties.
                let parts: Vec<&str> = short.split('/').collect();
                let disp = if parts.len() as i64 > cfg.path_depth && parts.len() >= 2 {
                    format!("{}/{}/\u{2026}/{}", parts[0], parts[1], parts[parts.len() - 1])
                } else {
                    short
                };
                self.push(
                    segs,
                    &cfg.bg_dir,
                    format!("{BOLD}{} {} {NORM}", self.fg_text, disp),
                );
            }
            "git" => {
                if self.git.branch.is_empty() {
                    return;
                }
                let bgc = if self.git.dirty {
                    &cfg.bg_git_dirty
                } else {
                    &cfg.bg_git_ok
                };
                self.push(
                    segs,
                    bgc,
                    format!(
                        "{BOLD}{} \u{2387} {}{}{} {NORM}",
                        self.fg_text,
                        trunc(&self.git.branch, cfg.name_max),
                        self.git.marks,
                        self.git.ab
                    ),
                );
            }
            "model" => {
                if p.model.is_empty() {
                    return;
                }
                let m = p.model.strip_prefix("Claude ").unwrap_or(&p.model);
                self.push(
                    segs,
                    &cfg.bg_model,
                    format!("{BOLD}{} \u{25C6} {} {NORM}", self.fg_text, m),
                );
            }
            "ctx" => {
                let cp = match p.ctx_pct {
                    Some(v) => v,
                    None => return,
                };
                let ci = round_pct(cp);
                let bar = make_bar(ci, cfg.bar_width, &cfg.bar_fill, &cfg.bar_empty);
                let cn = self.pct_fg(ci);
                self.push(
                    segs,
                    &cfg.bg_ctx,
                    format!(
                        "{} \u{2B21} {} {}% {}\u{2191}{} \u{2193}{} cr:{} cw:{} ",
                        cn,
                        bar,
                        ci,
                        self.fg_dim,
                        fmt_tok(p.tok_in),
                        fmt_tok(p.tok_out),
                        fmt_tok(p.tok_cr),
                        fmt_tok(p.tok_cw)
                    ),
                );
            }
            "limit5h" => self.seg_limit(segs, "5h", p.fh_pct, &p.fh_rst, &cfg.bg_5h),
            "limit7d" => self.seg_limit(segs, "7d", p.wd_pct, &p.wd_rst, &cfg.bg_7d),
            "cost" => {
                let c = match p.cost {
                    Some(v) if v != 0.0 => v,
                    _ => return,
                };
                self.push(
                    segs,
                    &cfg.bg_cost,
                    format!("{} ${:.*} ", self.fg_text, cfg.cost_decimals, c),
                );
            }
            "clock" => self.seg_clock(segs),
            "lines" => {
                if p.lines_add <= 0 && p.lines_del <= 0 {
                    return;
                }
                self.push(
                    segs,
                    &cfg.bg_lines,
                    format!(
                        " {}+{} {}-{} ",
                        self.fg_ok, p.lines_add, self.fg_hot, p.lines_del
                    ),
                );
            }
            "style" => {
                if p.out_style.is_empty() || p.out_style == "default" {
                    return;
                }
                self.push(
                    segs,
                    &cfg.bg_style,
                    format!("{} \u{270E} {} ", self.fg_text, p.out_style),
                );
            }
            "duration" => {
                if p.dur_ms <= 0 {
                    return;
                }
                self.push(
                    segs,
                    &cfg.bg_duration,
                    format!("{} \u{29D6} {} ", self.fg_text, fmt_duration(p.dur_ms)),
                );
            }
            "stash" => {
                if self.git.branch.is_empty() {
                    return;
                }
                let n = self.stash_count();
                if n > 0 {
                    self.push(
                        segs,
                        &cfg.bg_git_ok,
                        format!("{} \u{2691} {} ", self.fg_text, n),
                    );
                }
            }
            _ => {}
        }
    }

    fn seg_limit(&self, segs: &mut Vec<Seg>, label: &str, pct: Option<f64>, reset: &str, bgc: &str) {
        let pv = match pct {
            Some(v) => v,
            None => return,
        };
        let v = round_pct(pv);
        let bar = make_bar(v, self.cfg.bar_width, &self.cfg.bar_fill, &self.cfg.bar_empty);
        let cn = self.pct_fg(v);
        let cd = fmt_countdown(reset, self.now_epoch);
        let rst = if cd.is_empty() {
            String::new()
        } else {
            format!("{}\u{21BA}{}", self.fg_dim, cd)
        };
        self.push(
            segs,
            bgc,
            format!("{} {} {} {}% {} ", cn, label, bar, v, rst),
        );
    }

    fn seg_clock(&self, segs: &mut Vec<Seg>) {
        let cfg = self.cfg;
        if cfg.clock == "off" {
            return;
        }
        let (t, ap);
        if cfg.clock == "24h" {
            t = if cfg.clock_seconds {
                format!("{:02}:{:02}:{:02}", self.hour, self.min, self.sec)
            } else {
                format!("{:02}:{:02}", self.hour, self.min)
            };
            ap = String::new();
        } else {
            let mut h12 = self.hour % 12;
            if h12 == 0 {
                h12 = 12;
            }
            t = if cfg.clock_seconds {
                format!("{:02}:{:02}:{:02}", h12, self.min, self.sec)
            } else {
                format!("{:02}:{:02}", h12, self.min)
            };
            ap = format!(" {}", if self.hour < 12 { "am" } else { "pm" });
        }
        self.push(
            segs,
            &cfg.bg_clock,
            format!("{} \u{2299} {}{} ", self.fg_text, t, ap),
        );
    }

    fn stash_count(&self) -> i64 {
        if let Some(gd) = crate::git::git_dir_of(&self.p.cwd) {
            let logf = gd.join("logs").join("refs").join("stash");
            if let Ok(c) = std::fs::read_to_string(logf) {
                return c.lines().filter(|l| !l.trim().is_empty()).count() as i64;
            }
        }
        0
    }
}

fn print_range_pill(cfg: &Config, segs: &[Seg], start: usize, end: usize) -> String {
    let mut out = String::new();
    out.push_str(R);
    out.push_str(&fg(&segs[start].bg));
    out.push_str(&cfg.cap_l);
    for i in start..=end {
        out.push_str(&bg(&segs[i].bg));
        out.push_str(&segs[i].txt);
        if i < end {
            out.push_str(&bg(&segs[i + 1].bg));
            out.push_str(&fg(&segs[i].bg));
            out.push_str(&cfg.sep);
        }
    }
    out.push_str(R);
    out.push_str(&fg(&segs[end].bg));
    out.push_str(&cfg.cap_r);
    out.push_str(R);
    out
}

fn print_range_lean(cfg: &Config, segs: &[Seg], start: usize, end: usize) -> String {
    let mut out = String::new();
    for i in start..=end {
        out.push_str(R);
        out.push_str(&fg(&segs[i].bg));
        out.push_str(&segs[i].txt);
        if i < end {
            out.push_str(R);
            out.push_str(&cfg.lean_sep);
        }
    }
    out.push_str(R);
    out
}

fn print_range(cfg: &Config, segs: &[Seg], start: usize, end: usize) -> String {
    if cfg.style == "lean" {
        print_range_lean(cfg, segs, start, end)
    } else {
        print_range_pill(cfg, segs, start, end)
    }
}

fn term_cols() -> i64 {
    if let Ok(c) = std::env::var("COLUMNS") {
        if !c.is_empty() && c.bytes().all(|b| b.is_ascii_digit()) {
            return c.parse().unwrap_or(0);
        }
    }
    0
}

#[allow(clippy::too_many_arguments)]
pub fn render(
    cfg: &Config,
    p: &Payload,
    git: &GitInfo,
    home: &str,
    hour: u32,
    min: u32,
    sec: u32,
    now_epoch: i64,
) -> String {
    let ctx = Ctx {
        cfg,
        p,
        git,
        home,
        hour,
        min,
        sec,
        now_epoch,
        fg_text: fg(&cfg.fg_text),
        fg_dim: fg(&cfg.fg_dim),
        fg_ok: fg(&cfg.fg_ok),
        fg_warn: fg(&cfg.fg_warn),
        fg_hot: fg(&cfg.fg_hot),
    };

    let mut rows: Vec<String> = Vec::new();

    if cfg.layout == "auto" {
        let segs = ctx.build(&cfg.segments);
        let total = segs.len();
        if total == 0 {
            return String::new();
        }
        let w0 = term_cols();
        if w0 <= 0 || cfg.max_lines <= 1 {
            rows.push(print_range(cfg, &segs, 0, total - 1));
        } else {
            let mut w = w0 - cfg.wrap_margin;
            if w < 1 {
                w = 1;
            }
            let (cap_w, sep_w): (i64, i64) = if cfg.style == "lean" {
                (0, cfg.lean_sep.chars().count() as i64)
            } else {
                (2, 1)
            };
            let mut start = 0usize;
            let mut line = 1i64;
            let mut cur = cap_w + segs[0].len as i64;
            let mut i = 1usize;
            while i < total {
                let need = cur + sep_w + segs[i].len as i64;
                if need > w && line < cfg.max_lines {
                    rows.push(print_range(cfg, &segs, start, i - 1));
                    start = i;
                    line += 1;
                    cur = cap_w + segs[i].len as i64;
                } else {
                    cur = need;
                }
                i += 1;
            }
            rows.push(print_range(cfg, &segs, start, total - 1));
        }
    } else {
        for list in [&cfg.segments, &cfg.segments2, &cfg.segments3] {
            if list.is_empty() {
                continue;
            }
            let segs = ctx.build(list);
            if !segs.is_empty() {
                rows.push(print_range(cfg, &segs, 0, segs.len() - 1));
            }
        }
    }

    rows.join("\n")
}
