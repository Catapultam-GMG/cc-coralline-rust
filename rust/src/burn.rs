//! Burn-rate estimator + cross-session rate-limit stores, ported faithfully
//! from upstream statusline.sh (burn_sample / burn_eta_5h / burn_eta_7d /
//! burn_estimate and the rl_sample / rl_latest dir-set store).
//!
//! The 5h estimator is a line-for-line port of the awk program: dedup samples
//! by second, keep only the current window (latest reset), fit a slope over
//! integer-percent crossings inside the recent lookback, and trim the sample
//! file on physical rows. The rl store is a SET of atomically-created
//! directory entries named "<reset:%010d>_<pct:%07.3f>" so lexical order ==
//! numeric order; add = create_dir, read = list+max, gc = remove lower entries.
use crate::config::{msys_to_win, Config};
use crate::render::to_epoch;

// Per-window ceilings for the sentinel guard (#32): a reset further out than
// its window can possibly be is corrupt and must never become the high-water.
pub const RL_MAX_5H: i64 = 6 * 3600;
pub const RL_MAX_7D: i64 = 8 * 86400;

pub struct Burn {
    pub state: &'static str, // "active" | "idle" | "warming"
    pub label: &'static str, // "5h" | "7d" | ""
    pub eta: i64,            // seconds; only meaningful when active
    pub ttr: i64,            // seconds until the binding window resets
}

/// `<file>.d` — the dir-set companion of a store's .tsv path.
fn rl_dir(file: &str) -> String {
    let base = file.strip_suffix(".tsv").unwrap_or(file);
    format!("{base}.d")
}

/// Record one (pct, reset) high-water sample into the dir-set store.
pub fn rl_sample(file: &str, pct_raw: &str, resets_raw: &str, max_ahead: i64, now: i64) {
    if pct_raw.is_empty() {
        return;
    }
    let Some(reset) = to_epoch(resets_raw) else {
        return;
    };
    // Reject an implausibly-far-future reset (corrupt/sentinel snapshot).
    if reset > now + max_ahead {
        return;
    }
    let Ok(pct) = pct_raw.parse::<f64>() else {
        return;
    };
    let dir = msys_to_win(&rl_dir(file));
    let dpath = std::path::Path::new(&dir);
    if !dpath.is_dir() {
        let _ = std::fs::create_dir_all(dpath);
        // One-shot migration: a pre-dir-set build kept a flat <file>.tsv.
        let flat = msys_to_win(file);
        let _ = std::fs::remove_file(&flat);
        if let (Some(parent), Some(base)) = (
            std::path::Path::new(&flat).parent(),
            std::path::Path::new(&flat).file_name().and_then(|s| s.to_str()),
        ) {
            if let Ok(rd) = std::fs::read_dir(parent) {
                for e in rd.flatten() {
                    let name = e.file_name();
                    let name = name.to_string_lossy();
                    if name.starts_with(&format!("{base}.")) && name.ends_with(".tmp") {
                        let _ = std::fs::remove_file(e.path());
                    }
                }
            }
        }
    }
    if reset < 0 {
        return; // %010d of a negative value would not sort; upstream printf fails similarly
    }
    let entry = format!("{reset:010}_{pct:07.3}");
    let _ = std::fs::create_dir(dpath.join(entry));
}

/// Current window's high-water → (pct as recorded, reset epoch). Prunes
/// sentinel entries past `now + max_ahead` and every kept entry below the max.
pub fn rl_latest(file: &str, max_ahead: i64, now: i64) -> Option<(String, i64)> {
    let dir = msys_to_win(&rl_dir(file));
    let dpath = std::path::Path::new(&dir);
    let rd = std::fs::read_dir(dpath).ok()?;
    let mut snap: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(str::to_string))
        .filter(|n| n.as_bytes().first().is_some_and(u8::is_ascii_digit))
        .collect();
    snap.sort();
    if snap.is_empty() {
        return None;
    }
    // Entry name is "<reset>_<pct>": reset = everything before the LAST '_'
    // (bash ${d%_*}), pct = everything after the FIRST '_' (bash ${d#*_}).
    let reset_of = |d: &str| -> Option<i64> { d.rsplit_once('_')?.0.parse().ok() };
    let cut = now + max_ahead;
    let mut kept: Vec<String> = Vec::new();
    for d in snap {
        if reset_of(&d)? > cut {
            let _ = std::fs::remove_dir(dpath.join(&d)); // purge the poisoned sentinel
        } else {
            kept.push(d);
        }
    }
    let hi = kept.last()?.clone();
    let reset: i64 = reset_of(&hi)?;
    let pct = hi.splitn(2, '_').nth(1).unwrap_or("").to_string();
    for d in &kept {
        if *d != hi {
            let _ = std::fs::remove_dir(dpath.join(d));
        }
    }
    Some((pct, reset))
}

/// Append one 5h sample line ("now\tpct\treset_epoch") to the burn file.
pub fn burn_sample(file: &str, now: i64, pct_raw: &str, resets_raw: &str) {
    if pct_raw.is_empty() {
        return;
    }
    let Some(reset) = to_epoch(resets_raw) else {
        return;
    };
    if reset > now + RL_MAX_5H {
        return;
    }
    let path = msys_to_win(file);
    let p = std::path::Path::new(&path);
    if let Some(parent) = p.parent() {
        if !parent.is_dir() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
        let _ = write!(f, "{now}\t{pct_raw}\t{reset}\n");
    }
}

/// awk CONVFMT (%.6g) — how the trim rewrite stringifies a numeric pct.
fn fmt_g6(x: f64) -> String {
    if x == 0.0 {
        return "0".into();
    }
    let exp = x.abs().log10().floor() as i32;
    if (-4..6).contains(&exp) {
        let decimals = (5 - exp).max(0) as usize;
        let s = format!("{x:.decimals$}");
        if s.contains('.') {
            s.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            s
        }
    } else {
        // %g exponent form (percent values never reach this in practice)
        let mant = x / 10f64.powi(exp);
        let s = format!("{mant:.5}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        format!("{s}e{}{:02}", if exp < 0 { '-' } else { '+' }, exp.abs())
    }
}

struct Eta5 {
    state: &'static str,
    eta: Option<i64>, // None = inf
    ttr: i64,
}

/// The 5h recent-slope estimator; also trims the sample file (port of the awk).
fn burn_eta_5h(cfg: &Config, now: i64) -> Eta5 {
    let inf = |state, ttr| Eta5 { state, eta: None, ttr };
    let path = msys_to_win(&cfg.burn_file);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return inf("warming", 0);
    };

    // Parse + dedup by whole-second epoch, keeping first-seen order and the
    // last-seen pct/reset per second. Drop sentinel rows (reset too far out).
    let mut ord: Vec<i64> = Vec::new();
    let mut pct: std::collections::HashMap<i64, f64> = std::collections::HashMap::new();
    let mut rst: std::collections::HashMap<i64, i64> = std::collections::HashMap::new();
    let mut dropped = false;
    let mut physical_rows = 0i64;
    for line in text.lines() {
        physical_rows += 1;
        let mut it = line.split('\t');
        let f1 = it.next().unwrap_or("");
        let f2 = it.next().unwrap_or("");
        let f3 = it.next().unwrap_or("");
        if f2.is_empty() {
            continue;
        }
        let e = f1.parse::<f64>().unwrap_or(0.0) as i64;
        let r = f3.parse::<f64>().unwrap_or(0.0) as i64;
        if r > now + RL_MAX_5H {
            dropped = true;
            continue;
        }
        if !pct.contains_key(&e) {
            ord.push(e);
        }
        pct.insert(e, f2.parse::<f64>().unwrap_or(0.0));
        rst.insert(e, r);
    }

    let result;
    if ord.is_empty() {
        result = inf("warming", 0);
    } else {
        // Fit the slope over the CURRENT window only (latest reset).
        let cur = ord.iter().map(|e| rst[e]).max().unwrap_or(0);
        let cord: Vec<i64> = ord.iter().copied().filter(|e| rst[e] == cur).collect();
        let m = cord.len();
        let lp = pct[&cord[m - 1]];
        let ttr = (cur - now).max(0);
        let cwin = now - cfg.burn_window;
        let minspan = cfg.burn_window / 10;
        let (mut fc_t, mut fc_p, mut lc_t, mut lc_p) = (0i64, -1i64, 0i64, -1i64);
        let mut ncross = 0;
        let mut anycross = false;
        for i in 1..m {
            let a = pct[&cord[i - 1]] as i64; // awk int(): truncate toward zero
            let b = pct[&cord[i]] as i64;
            if b > a {
                anycross = true;
                let ct = cord[i];
                if ct >= cwin && ct <= now {
                    if fc_p < 0 {
                        fc_t = ct;
                        fc_p = b;
                    }
                    lc_t = ct;
                    lc_p = b;
                    ncross += 1;
                }
            }
        }
        if ncross >= 2 && lc_t > fc_t && lc_p > fc_p && (lc_t - fc_t) >= minspan {
            let rate = (lc_p - fc_p) as f64 / (lc_t - fc_t) as f64;
            let eta = ((100.0 - lp) / rate).max(0.0);
            result = Eta5 {
                state: "active",
                eta: Some(eta.round() as i64),
                ttr,
            };
        } else if anycross && ncross == 0 {
            result = inf("idle", ttr);
        } else {
            result = inf("warming", ttr);
        }
        // Trim on PHYSICAL rows so same-second render bursts can't grow the
        // file unbounded; also rewrite when a sentinel row was dropped above.
        if physical_rows > cfg.burn_trim || dropped {
            let lo = (ord.len() as i64 - cfg.burn_trim).max(0) as usize;
            let mut out = String::new();
            for e in &ord[lo..] {
                out.push_str(&format!("{e}\t{}\t{}\n", fmt_g6(pct[e]), rst[e]));
            }
            let tmp = format!("{path}.{}.tmp", std::process::id());
            if std::fs::write(&tmp, out).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }
    // Sweep tmps orphaned by dead sessions — every call, like upstream (the
    // sweep sits after the awk, outside the trim condition).
    let own = format!("{path}.{}.tmp", std::process::id());
    let p = std::path::Path::new(&path);
    if let (Some(parent), Some(base)) = (p.parent(), p.file_name().and_then(|s| s.to_str())) {
        if let Ok(rd) = std::fs::read_dir(parent) {
            for e in rd.flatten() {
                let name = e.file_name();
                let name = name.to_string_lossy().to_string();
                if name.starts_with(&format!("{base}."))
                    && name.ends_with(".tmp")
                    && e.path() != std::path::Path::new(&own)
                {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
    result
}

/// The stateless 7d estimator: average burn since the window opened.
fn burn_eta_7d(pct_raw: &str, resets_raw: &str, now: i64) -> (Option<i64>, i64) {
    if pct_raw.is_empty() {
        return (None, 0);
    }
    let Some(r) = to_epoch(resets_raw) else {
        return (None, 0);
    };
    let ttr = (r - now).max(0);
    let p = pct_raw.parse::<f64>().unwrap_or(0.0);
    let ws = r - 7 * 86400;
    let el = now - ws;
    if p <= 0.0 || el <= 0 {
        return (None, ttr);
    }
    let rate = p / el as f64;
    let eta = ((100.0 - p) / rate).max(0.0);
    (Some(eta.round() as i64), ttr)
}

/// Pick the binding limit (whichever projects empty first) → Burn.
pub fn burn_estimate(cfg: &Config, fh_pct: &str, fh_rst: &str, wd_pct: &str, wd_rst: &str, now: i64) -> Burn {
    let e5 = burn_eta_5h(cfg, now);
    // For 7d, when limit-sync is on, project from the same synced value the
    // limit7d segment shows so the two can't contradict each other.
    let (e7, t7) = if cfg.limit_sync {
        match rl_latest(&cfg.rl7d_file, RL_MAX_7D, now) {
            Some((pct, rst)) => burn_eta_7d(&pct, &rst.to_string(), now),
            None => burn_eta_7d(wd_pct, wd_rst, now),
        }
    } else {
        burn_eta_7d(wd_pct, wd_rst, now)
    };
    let _ = (fh_pct, fh_rst); // 5h reads the shared sample file, not the payload
    match (e5.eta, e7) {
        (Some(a), Some(b)) if a <= b => Burn { state: "active", label: "5h", eta: a, ttr: e5.ttr },
        (Some(a), None) => Burn { state: "active", label: "5h", eta: a, ttr: e5.ttr },
        (_, Some(b)) => Burn { state: "active", label: "7d", eta: b, ttr: t7 },
        _ => Burn {
            state: if e5.state == "idle" { "idle" } else { "warming" },
            label: "",
            eta: 0,
            ttr: 0,
        },
    }
}
