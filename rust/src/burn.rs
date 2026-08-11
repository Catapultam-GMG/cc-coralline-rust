//! Burn-rate estimator (range-to-empty), ported from upstream statusline.sh's
//! `burn_eta_5h` / `burn_eta_7d` / `burn_estimate`.
//!
//! The 5h estimator is a line-for-line port of the awk program: validate every
//! TSV row into integers, dedup observations by (reset, sample second), keep
//! only the current window, fit a slope over integer-percent crossings inside
//! the recent lookback, and trim the file on physical rows (or when a row had
//! to be healed away). All arithmetic is exact integer arithmetic with
//! midpoint-to-even rounding, so the native binary and bash agree to the second.
use crate::config::msys_to_win;
use crate::state::{burn_tmp_sweep, round_even, Gate};

pub use crate::state::{RL_MAX_5H, RL_MAX_7D};

pub struct Burn {
    pub state: &'static str, // "active" | "idle" | "warming"
    pub label: &'static str, // "5h" | "7d" | ""
    pub eta: i64,            // seconds; only meaningful when active
    pub ttr: i64,            // seconds until the binding window resets
}

struct Eta {
    state: &'static str,
    eta: Option<i64>, // None = inf
    ttr: i64,
}

const WARMING: Eta = Eta {
    state: "warming",
    eta: None,
    ttr: 0,
};

/// awk `epoch()`: 1..12 digits, no leading zero, bounded by year 9999.
fn row_epoch(raw: &str) -> Option<i64> {
    if raw.is_empty() || raw.len() > 12 || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if raw.len() > 1 && raw.as_bytes()[0] == b'0' {
        return None;
    }
    let v: i64 = raw.parse().ok()?;
    if v > 253_402_300_799 {
        return None;
    }
    Some(v)
}

/// awk `pct_milli()`: the canonical `%03d.%03d` row form, or the same raw
/// decimal `state_pct` accepts. Both round ties to even at the .001 digit.
fn row_pct(raw: &str) -> Option<i64> {
    if raw.is_empty() || raw.len() > 10 {
        return None;
    }
    let canonical = raw.len() == 7
        && raw.as_bytes()[3] == b'.'
        && raw[0..3].bytes().all(|b| b.is_ascii_digit())
        && raw[4..7].bytes().all(|b| b.is_ascii_digit());
    if canonical {
        let whole: i64 = raw[0..3].parse().ok()?;
        let frac = &raw[4..7];
        if whole > 100 || (whole == 100 && frac.bytes().any(|b| b != b'0')) {
            return None;
        }
        let milli = whole * 1000 + frac.parse::<i64>().ok()?;
        return if milli <= 100_000 { Some(milli) } else { None };
    }
    crate::state::state_pct(raw).map(|(m, _)| m)
}

fn canon(milli: i64) -> String {
    format!("{}.{:03}", milli / 1000, milli % 1000)
}

/// The 5h recent-slope estimator; also trims/heals the sample file.
fn burn_eta_5h(gate: &Gate, now: i64) -> Eta {
    let base = gate.burn_base.as_deref();
    let text = match base {
        Some(b) => std::fs::read_to_string(msys_to_win(b)).ok(),
        None => None,
    };

    // Observations keyed by (reset, sample second), first-seen order preserved.
    let mut obs: Vec<(i64, i64, i64)> = Vec::new();
    let mut idx: std::collections::HashMap<(i64, i64), usize> = std::collections::HashMap::new();
    let add = |obs: &mut Vec<(i64, i64, i64)>,
                   idx: &mut std::collections::HashMap<(i64, i64), usize>,
                   r: i64,
                   s: i64,
                   p: i64| {
        match idx.get(&(r, s)) {
            Some(&at) => {
                if p > obs[at].2 {
                    obs[at].2 = p;
                }
            }
            None => {
                idx.insert((r, s), obs.len());
                obs.push((r, s, p));
            }
        }
    };

    let mut physical = 0i64;
    let mut bytes = 0i64;
    let mut heal = false;
    let mut incomplete = false;
    if let Some(text) = text.as_deref() {
        let mut lines: Vec<&str> = text.split('\n').collect();
        if lines.last() == Some(&"") {
            lines.pop();
        }
        for line in lines {
            physical += 1;
            bytes += line.len() as i64 + 1;
            if physical > 4096 || bytes > 1_048_576 || line.len() > 4096 {
                incomplete = true;
                break;
            }
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 3 {
                continue;
            }
            let (Some(s), Some(p), Some(r)) = (row_epoch(f[0]), row_pct(f[1]), row_epoch(f[2]))
            else {
                continue;
            };
            if s > now + 300 || r < s || r > now + RL_MAX_5H {
                heal = true;
                continue;
            }
            add(&mut obs, &mut idx, r, s, p);
        }
    }
    // A killed render leaves its trim temporary behind; sweep on the mutating
    // path only, before anything else touches the store (upstream ordering).
    let writable = gate.mutate && text.is_some();
    if writable {
        burn_tmp_sweep(base.unwrap());
    }
    if incomplete {
        return WARMING;
    }

    // Trim on PHYSICAL rows (sub-second render bursts dedup away, so a
    // distinct-observation cap would never fire), or when a row was healed out.
    if writable && (physical > gate.burn_trim || heal) {
        let b = base.unwrap();
        let lo = (obs.len() as i64 - gate.burn_trim).max(0) as usize;
        let mut out = String::new();
        for (r, s, p) in &obs[lo..] {
            out.push_str(&format!("{}\t{}\t{}\n", s, canon(*p), r));
        }
        let native = msys_to_win(b);
        let tmp = format!("{native}.{}.tmp", std::process::id());
        if !std::path::Path::new(&tmp).exists() && std::fs::write(&tmp, out).is_ok() {
            if std::fs::rename(&tmp, &native).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }

    // This render's own reading counts as an observation even with no file yet.
    if gate.burn_valid {
        add(
            &mut obs,
            &mut idx,
            gate.burn_rst,
            gate.burn_samp,
            gate.cur5.pct,
        );
    }

    let maxrst = obs.iter().map(|(r, _, _)| *r).max().unwrap_or(0);
    if maxrst <= 0 {
        return WARMING;
    }
    // Current window only: mixing windows lets the fit pair two samples seconds
    // apart but tens of percent apart, giving a near-vertical bogus rate.
    let mut order: Vec<i64> = Vec::new();
    let mut by_sample: std::collections::HashMap<i64, i64> = std::collections::HashMap::new();
    for (r, s, p) in &obs {
        if *r != maxrst {
            continue;
        }
        match by_sample.get_mut(s) {
            Some(cur) => {
                if p > cur {
                    *cur = *p;
                }
            }
            None => {
                by_sample.insert(*s, *p);
                order.push(*s);
            }
        }
    }
    if order.is_empty() {
        return WARMING;
    }
    order.sort_unstable();
    let latest = by_sample[order.last().unwrap()];
    let ttr = (maxrst - now).max(0);
    let cutoff = now - gate.burn_window;
    let minspan = gate.burn_window / 10;

    let (mut fc_t, mut fc_p, mut lc_t, mut lc_p) = (0i64, -1i64, 0i64, -1i64);
    let mut ncross = 0;
    let mut anycross = false;
    for i in 1..order.len() {
        let a = by_sample[&order[i - 1]] / 1000; // integer percent
        let b = by_sample[&order[i]] / 1000;
        if b > a {
            anycross = true;
            let ct = order[i];
            if ct >= cutoff && ct <= now {
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
        let span = lc_t - fc_t;
        let delta = lc_p - fc_p;
        if let Some(eta) = round_even(
            (100_000 - latest) as i128 * span as i128,
            delta as i128 * 1000,
        ) {
            return Eta {
                state: "active",
                eta: Some(eta),
                ttr,
            };
        }
    }
    Eta {
        state: if anycross && ncross == 0 { "idle" } else { "warming" },
        eta: None,
        ttr,
    }
}

/// The stateless 7d estimator: average burn since the window opened.
fn burn_eta_7d(pct_milli: Option<i64>, reset: Option<i64>, now: i64) -> (Option<i64>, i64) {
    let (Some(pct), Some(rst)) = (pct_milli, reset) else {
        return (None, 0);
    };
    let ttr = (rst - now).max(0);
    let elapsed = now - (rst - 604_800);
    if pct <= 0 || elapsed < 1 || elapsed > RL_MAX_7D {
        return (None, ttr);
    }
    (
        round_even((100_000 - pct) as i128 * elapsed as i128, pct as i128),
        ttr,
    )
}

/// Pick the binding limit (whichever projects empty first) → Burn.
pub fn burn_estimate(gate: &Gate, limit_sync: bool, now: i64) -> Burn {
    let mut e5 = burn_eta_5h(gate, now);
    // Whenever the synced state is what the gauge draws, the ETA has to be
    // projected from that same window; burn_eta_5h reports the window it used
    // as NOW + ttr, so a mismatch falls back to warming rather than putting an
    // ETA for one window beside a gauge for another.
    if limit_sync && gate.rl5.valid && now + e5.ttr != gate.rl5.rst {
        e5 = WARMING;
    }
    // The ownership rule covers the projection too, and it has to be the SAME
    // rule the 7d gauge uses, or the bar and the gauge report different windows.
    let (e7, t7) = if limit_sync && gate.rl7.valid {
        burn_eta_7d(Some(gate.rl7.pct), Some(gate.rl7.rst), now)
    } else if gate.cur7.valid {
        burn_eta_7d(Some(gate.cur7.pct), Some(gate.cur7.rst), now)
    } else {
        burn_eta_7d(None, None, now)
    };

    match (e5.eta, e7) {
        (Some(a), Some(b)) if a <= b => Burn {
            state: "active",
            label: "5h",
            eta: a,
            ttr: e5.ttr,
        },
        (Some(a), None) => Burn {
            state: "active",
            label: "5h",
            eta: a,
            ttr: e5.ttr,
        },
        (_, Some(b)) => Burn {
            state: "active",
            label: "7d",
            eta: b,
            ttr: t7,
        },
        _ => Burn {
            state: if e5.state == "idle" { "idle" } else { "warming" },
            label: "",
            eta: 0,
            ttr: 0,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_pct_takes_both_forms() {
        assert_eq!(row_pct("041.500"), Some(41500));
        assert_eq!(row_pct("41.5"), Some(41500));
        assert_eq!(row_pct("100.000"), Some(100000));
        assert!(row_pct("101.000").is_none());
        assert!(row_pct("41,5").is_none());
    }

    #[test]
    fn seven_day_projection_is_exact() {
        // 50% burned with exactly half the window elapsed → the other half left.
        let now = 1_000_000;
        let rst = now + 302_400;
        let (eta, ttr) = burn_eta_7d(Some(50_000), Some(rst), now);
        assert_eq!(ttr, 302_400);
        assert_eq!(eta, Some(302_400));
    }
}
