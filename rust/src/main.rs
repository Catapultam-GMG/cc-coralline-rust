// Build as a Windows GUI-subsystem binary so the OS never allocates (or briefly
// flashes) a console window for this process. stdout still works — the launcher
// gives us a redirected pipe whose handle we inherit regardless of subsystem.
// No-op off Windows.
#![cfg_attr(windows, windows_subsystem = "windows")]

//! coralline — native (Rust) statusline renderer for Claude Code.
//!
//! A single self-contained exe, byte-identical in output to the bash
//! statusline.sh, but spawning ~100x faster (no bash + jq + git subprocess
//! chain per render — critical on Windows, where each spawn is scanned/forked
//! expensively, and when many sessions render every second).
//!
//! Contract: read the statusline JSON payload on stdin, print the rendered bar
//! on stdout. Per-session output cache + blanking guard so a killed/errored
//! render never blanks the bar. Branch comes from .git/HEAD instantly; dirty
//! marks / ahead-behind ride a background cache refreshed by a detached
//! `--git-refresh` child (a native-port enhancement; output matches upstream).
use std::io::Read;
use std::panic::AssertUnwindSafe;
use std::time::{SystemTime, UNIX_EPOCH};

mod burn;
mod config;
mod float;
mod git;
mod json;
mod render;
mod state;
mod subagent;

use config::Config;
use json::Json;

/// What the payload's `cost.total_cost_usd` is, in upstream's `_COST_KIND`
/// terms: absent/empty (`missing`), a usable scalar, or something else.
#[derive(PartialEq)]
pub enum CostKind {
    Missing,
    Scalar,
    Invalid,
}

pub struct Payload {
    pub cwd: String,
    pub model: String,
    pub ctx_pct: String, // jq-tostring form; "" when absent
    pub ctx_empty: bool, // a valid context window that simply reports nothing
    pub json_ok: bool,   // the payload parsed and its root is an object
    pub tok_in: i64,
    pub tok_out: i64,
    pub tok_cr: i64,
    pub tok_cw: i64,
    pub fh_pct: String, // jq-tostring form, for burn/limit-sync sampling
    pub fh_rst: String,
    pub wd_pct: String,
    pub wd_rst: String,
    pub cost: String,
    pub cost_kind: CostKind,
    pub lines_add: i64,
    pub lines_del: i64,
    pub out_style: String,
    pub dur_ms: i64,
    pub effort: String,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 3 && args[1] == "--git-refresh" {
        let coralline_dir = format!("{}/.claude/coralline", home_dir());
        git::refresh(&args[2], &coralline_dir);
        return;
    }
    if args.len() >= 2 && args[1] == "--float-carrier" {
        let once = args.iter().any(|a| a == "--once");
        float::carrier(once);
        return;
    }
    if args.len() >= 2 && args[1] == "--subagent" {
        // Panel mode exits before every main-bar side effect (git probe,
        // burn/limit sampling, float readout, output cache) — same as upstream.
        let mut payload = String::new();
        let _ = std::io::stdin().read_to_string(&mut payload);
        let cfg = Config::load(&home_dir());
        let out = std::panic::catch_unwind(AssertUnwindSafe(|| {
            subagent::run(&payload, &cfg, now_epoch())
        }))
        .unwrap_or_default();
        print!("{out}");
        return;
    }
    run();
}

fn run() {
    let mut payload = String::new();
    let _ = std::io::stdin().read_to_string(&mut payload);

    let home = home_dir();
    let coralline_dir = format!("{home}/.claude/coralline");
    let cache_dir = format!("{coralline_dir}/.cache/out-native");
    let _ = std::fs::create_dir_all(&cache_dir);

    let parsed = json::parse(&payload);
    let sid = session_key(parsed.as_ref());
    let cache = format!("{cache_dir}/{sid}");

    let out = std::panic::catch_unwind(AssertUnwindSafe(|| {
        render_all(parsed.as_ref(), &home, &coralline_dir)
    }))
    .unwrap_or_default();

    if !out.is_empty() {
        println!("{out}");
        let tmp = format!("{cache}.tmp");
        if std::fs::write(&tmp, format!("{out}\n")).is_ok() {
            let _ = std::fs::rename(&tmp, &cache);
        }
    } else if let Ok(c) = std::fs::read_to_string(&cache) {
        print!("{c}");
    }
}

fn render_all(j: Option<&Json>, home: &str, coralline_dir: &str) -> String {
    let j = match j {
        Some(x) => x,
        None => return String::new(),
    };
    let cfg = Config::load(home);
    let p = extract(j);

    // Float segments also drive git gathering when VL_FLOAT is on, matching
    // upstream's `_SEG_SCAN` (so a `git`/`project` float segment has data).
    let float_segs = if cfg.float { cfg.float_segments.as_str() } else { "" };
    let all_segs = format!(
        " {} {} {} {} ",
        cfg.segments, cfg.segments2, cfg.segments3, float_segs
    );
    let uses = |name: &str| all_segs.contains(&format!(" {name} "));
    let use_git = uses("git") || uses("stash") || uses("project") || uses("worktree");

    let git = git::gather(&p.cwd, coralline_dir, use_git);
    let (h, m, s) = local_hms();
    let now = now_epoch();

    // Burn / limit-sync state, gated on the segment scan exactly like upstream.
    // The disabled path does no state work at all; CORALLINE_NO_SAMPLE keeps
    // every read but forbids mutation, so a preview render's sentinel values
    // never poison the cross-session stores.
    let uses_burn = uses("burn");
    // burn takes both limit gates, not just 7d: it can bind to either window and
    // its 5h projection is rebound to the synced state below.
    let gate5 = cfg.limit_sync && (uses("limit5h") || uses_burn);
    let gate7 = cfg.limit_sync && (uses("limit7d") || uses_burn);
    let mut gate = None;
    if uses_burn || gate5 || gate7 {
        let mut g = state::Gate::new(
            &p.fh_pct,
            &p.fh_rst,
            &p.wd_pct,
            &p.wd_rst,
            now,
            &cfg.burn_file,
            &cfg.rl5h_file,
            &cfg.rl7d_file,
            cfg.burn_window,
            cfg.burn_trim,
        );
        if g.mutate {
            if uses_burn {
                g.burn_sample();
            }
            if gate5 {
                g.rl_sample(5);
            }
            if gate7 {
                g.rl_sample(7);
            }
        }
        if cfg.limit_sync {
            if gate5 {
                g.resolve(5, now);
            }
            if gate7 {
                g.resolve(7, now);
            }
        }
        gate = Some(g);
    }
    let burn_est = match (&gate, uses_burn) {
        (Some(g), true) => Some(burn::burn_estimate(g, cfg.limit_sync, now)),
        _ => None,
    };

    // seg_dir collapses the *shell* $HOME (matches upstream `${cwd/#$HOME/~}`),
    // which differs from the Windows USERPROFILE used for filesystem paths.
    render::render(
        &cfg,
        &p,
        &git,
        &shell_home(),
        h,
        m,
        s,
        now,
        burn_est.as_ref(),
        gate.as_ref(),
    )
}

/// Drop C0, DEL, and C1 control characters — upstream's jq `scrub`, applied to
/// every extracted field so a crafted payload can't smuggle terminal escapes.
pub(crate) fn scrub(s: &str) -> String {
    s.chars()
        .filter(|&c| {
            let u = c as u32;
            !(u < 0x20 || u == 0x7f || (0x80..=0x9f).contains(&u))
        })
        .collect()
}

fn extract(j: &Json) -> Payload {
    let s = |path: &[&str]| scrub(j.path(path).and_then(|v| v.as_str()).unwrap_or(""));
    let f = |path: &[&str]| j.path(path).and_then(|v| v.as_f64());
    let i = |path: &[&str]| f(path).map(|x| x as i64).unwrap_or(0);
    // jq `// ""` then `tostring`: strings and numbers survive, everything else
    // (absent, null, false) reads as the empty field.
    let tok = |path: &[&str]| match j.path(path) {
        Some(Json::Str(st)) => scrub(st),
        Some(Json::Num(n)) => scrub(&fmt_num(*n)),
        _ => String::new(),
    };

    let cwd = {
        let w = s(&["workspace", "current_dir"]);
        if !w.is_empty() {
            w
        } else {
            s(&["cwd"])
        }
    };

    // ctx_empty: a context window that is absent, or present but reporting no
    // percentage — the only shape VL_CTX_ALWAYS_SHOW is allowed to render as 0%.
    let ctx_empty = match j.path(&["context_window"]) {
        None | Some(Json::Null) => true,
        Some(Json::Obj(_)) => match j.path(&["context_window", "used_percentage"]) {
            None | Some(Json::Null) => true,
            Some(Json::Str(v)) => v.is_empty(),
            _ => false,
        },
        _ => false,
    };

    let cost_kind = match j.path(&["cost"]) {
        None | Some(Json::Null) => CostKind::Missing,
        Some(Json::Obj(_)) => match j.path(&["cost", "total_cost_usd"]) {
            None | Some(Json::Null) => CostKind::Missing,
            Some(Json::Str(v)) if v.is_empty() => CostKind::Missing,
            Some(Json::Str(v)) => {
                if scrub(v) != *v {
                    CostKind::Invalid
                } else {
                    CostKind::Scalar
                }
            }
            Some(Json::Num(_)) => CostKind::Scalar,
            _ => CostKind::Invalid,
        },
        _ => CostKind::Invalid,
    };

    Payload {
        cwd,
        model: s(&["model", "display_name"]),
        ctx_pct: tok(&["context_window", "used_percentage"]),
        ctx_empty,
        json_ok: matches!(j, Json::Obj(_)),
        tok_in: i(&["context_window", "total_input_tokens"]),
        tok_out: i(&["context_window", "total_output_tokens"]),
        tok_cr: i(&["context_window", "current_usage", "cache_read_input_tokens"]),
        tok_cw: i(&["context_window", "current_usage", "cache_creation_input_tokens"]),
        fh_pct: tok(&["rate_limits", "five_hour", "used_percentage"]),
        fh_rst: tok(&["rate_limits", "five_hour", "resets_at"]),
        wd_pct: tok(&["rate_limits", "seven_day", "used_percentage"]),
        wd_rst: tok(&["rate_limits", "seven_day", "resets_at"]),
        cost: tok(&["cost", "total_cost_usd"]),
        cost_kind,
        lines_add: i(&["cost", "total_lines_added"]),
        lines_del: i(&["cost", "total_lines_removed"]),
        out_style: s(&["output_style", "name"]),
        dur_ms: i(&["cost", "total_duration_ms"]),
        effort: s(&["effort", "level"]),
    }
}

/// Format a JSON number the way jq's tostring would (integer if whole).
pub(crate) fn fmt_num(n: f64) -> String {
    if n.fract() == 0.0 {
        format!("{}", n as i64)
    } else {
        format!("{}", n)
    }
}

fn session_key(j: Option<&Json>) -> String {
    let mut sid = String::new();
    if let Some(j) = j {
        if let Some(s) = j.path(&["session_id"]).and_then(|v| v.as_str()) {
            sid = s.to_string();
        }
        if sid.is_empty() {
            let cwd = j
                .path(&["workspace", "current_dir"])
                .and_then(|v| v.as_str())
                .or_else(|| j.path(&["cwd"]).and_then(|v| v.as_str()))
                .unwrap_or("");
            sid = format!("cwd-{cwd}");
        }
    }
    let sanitized: String = sid
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if sanitized.is_empty() {
        "default".into()
    } else {
        sanitized
    }
}

/// Home directory for filesystem paths (config, cache). USERPROFILE is a native
/// Windows path Rust's std::fs understands (unlike MSYS `/c/...`).
fn home_dir() -> String {
    if let Ok(u) = std::env::var("USERPROFILE") {
        if !u.is_empty() {
            return u;
        }
    }
    if let (Ok(d), Ok(p)) = (std::env::var("HOMEDRIVE"), std::env::var("HOMEPATH")) {
        if !d.is_empty() {
            return format!("{d}{p}");
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        return h;
    }
    "C:\\Users\\Default".into()
}

/// Shell $HOME, used only by seg_dir's `~` collapse to match upstream's
/// `${cwd/#$HOME/~}`. Falls back to the filesystem home if HOME is unset.
fn shell_home() -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => h,
        _ => home_dir(),
    }
}

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(windows)]
fn local_hms() -> (u32, u32, u32) {
    #[repr(C)]
    struct SystemTimeW {
        w_year: u16,
        w_month: u16,
        w_day_of_week: u16,
        w_day: u16,
        w_hour: u16,
        w_minute: u16,
        w_second: u16,
        w_milliseconds: u16,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetLocalTime(lp: *mut SystemTimeW);
    }
    unsafe {
        let mut st: SystemTimeW = std::mem::zeroed();
        GetLocalTime(&mut st);
        (st.w_hour as u32, st.w_minute as u32, st.w_second as u32)
    }
}

// Linux/macOS: honor the system timezone via libc localtime_r, matching bash's
// `date` (zero-dep — libc is always linked on unix).
#[cfg(unix)]
fn local_hms() -> (u32, u32, u32) {
    #[repr(C)]
    struct Tm {
        sec: i32,
        min: i32,
        hour: i32,
        mday: i32,
        mon: i32,
        year: i32,
        wday: i32,
        yday: i32,
        isdst: i32,
        gmtoff: i64,
        zone: *const u8,
    }
    extern "C" {
        fn time(t: *mut i64) -> i64;
        fn localtime_r(t: *const i64, result: *mut Tm) -> *mut Tm;
    }
    unsafe {
        let mut now_t: i64 = 0;
        time(&mut now_t);
        let mut tm: Tm = std::mem::zeroed();
        if localtime_r(&now_t, &mut tm).is_null() {
            let day = now_t.rem_euclid(86400);
            return ((day / 3600) as u32, ((day % 3600) / 60) as u32, (day % 60) as u32);
        }
        (tm.hour as u32, tm.min as u32, tm.sec as u32)
    }
}

// Fallback for any other target: UTC.
#[cfg(not(any(windows, unix)))]
fn local_hms() -> (u32, u32, u32) {
    let secs = now_epoch();
    let day = secs.rem_euclid(86400);
    (
        (day / 3600) as u32,
        ((day % 3600) / 60) as u32,
        (day % 60) as u32,
    )
}
