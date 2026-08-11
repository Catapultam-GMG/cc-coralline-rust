//! Canonical burn / limit state layer — a port of upstream statusline.sh's
//! `state_*` block (the 2026-08 rewrite that replaced the float-based sampler).
//!
//! Everything the stores hold is validated into integers first: a percentage
//! becomes milli-percent (0..=100000, ties-to-even at the .001 digit), an epoch
//! becomes a bounded non-negative integer, and a store entry name is accepted
//! only in its exact `<reset:%010d>_<pct:%03d.%03d>` shape. Paths are
//! canonicalized once per render and refused when they alias each other or
//! traverse a symlink, so a hostile config cannot aim a store at something else.
use crate::config::msys_to_win;
use crate::render::iso_epoch_strict;

// Per-window ceilings: a reset further out than its window can possibly be is
// corrupt and must never become the high-water (#32).
pub const RL_MAX_5H: i64 = 6 * 3600;
pub const RL_MAX_7D: i64 = 8 * 86400;

/// One validated (percentage, reset) observation.
#[derive(Default, Clone)]
pub struct Reading {
    pub valid: bool,
    pub pct: i64, // milli-percent
    pub canon: String,
    pub rst: i64,
}

/// `state_pct`: strict raw decimal → milli-percent, ties-to-even at .001.
pub fn state_pct(raw: &str) -> Option<(i64, String)> {
    if raw.len() > 10 {
        return None;
    }
    let (whole, frac) = match raw.split_once('.') {
        Some((w, f)) => {
            if f.is_empty() || f.len() > 6 || !f.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            (w, f)
        }
        None => (raw, ""),
    };
    let ok_whole = match whole.len() {
        1 => whole.bytes().all(|b| b.is_ascii_digit()),
        2 => whole.as_bytes()[0] != b'0' && whole.bytes().all(|b| b.is_ascii_digit()),
        3 => whole == "100",
        _ => false,
    };
    if !ok_whole {
        return None;
    }
    if whole == "100" && frac.bytes().any(|b| b != b'0') {
        return None;
    }
    let six: String = frac.chars().chain(std::iter::repeat('0')).take(6).collect();
    let keep: i64 = six[0..3].parse().ok()?;
    let rest: i64 = six[3..6].parse().ok()?;
    let mut milli = whole.parse::<i64>().ok()? * 1000 + keep;
    if rest > 500 || (rest == 500 && milli % 2 == 1) {
        milli += 1;
    }
    if milli > 100_000 {
        return None;
    }
    Some((milli, format!("{:03}.{:03}", milli / 1000, milli % 1000)))
}

/// `state_epoch`: strict non-negative integer seconds, bounded by `width` digits.
pub fn state_epoch(raw: &str, width: usize) -> Option<i64> {
    if !(width == 10 || width == 12) || raw.is_empty() || raw.len() > width {
        return None;
    }
    if !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if raw.len() > 1 && raw.as_bytes()[0] == b'0' {
        return None;
    }
    let v: i64 = raw.parse().ok()?;
    if v > 253_402_300_799 {
        return None;
    }
    if width == 10 && v > 9_999_999_999 {
        return None;
    }
    Some(v)
}

/// `state_payload_epoch`: canonical UTC ISO or a strict epoch, nothing else.
pub fn state_payload_epoch(raw: &str, width: usize) -> Option<i64> {
    if raw.len() > 27 {
        return None;
    }
    if raw.contains('T') {
        if !iso_canonical(raw) {
            return None;
        }
        let e = iso_epoch_strict(raw)?;
        state_epoch(&e.to_string(), width)
    } else {
        state_epoch(raw, width)
    }
}

/// `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$`
fn iso_canonical(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 20 || *b.last().unwrap() != b'Z' {
        return false;
    }
    let head = &b[..19];
    for (i, &c) in head.iter().enumerate() {
        let ok = match i {
            4 | 7 => c == b'-',
            10 => c == b'T',
            13 | 16 => c == b':',
            _ => c.is_ascii_digit(),
        };
        if !ok {
            return false;
        }
    }
    let mid = &b[19..b.len() - 1];
    if mid.is_empty() {
        return true;
    }
    mid[0] == b'.' && (1..=6).contains(&(mid.len() - 1)) && mid[1..].iter().all(u8::is_ascii_digit)
}

/// `state_round_even`: exact non-negative rational, midpoint-to-even.
pub fn round_even(n: i128, d: i128) -> Option<i64> {
    if d <= 0 {
        return None;
    }
    let mut q = n / d;
    let r = n % d;
    if r * 2 > d || (r * 2 == d && q % 2 == 1) {
        q += 1;
    }
    i64::try_from(q).ok()
}

// ── Path canonicalization ────────────────────────────────────────────────────

/// Lexical absolute path: backslashes folded, `.`/`..` resolved, no trailing
/// slash. UNC forms are refused, matching `state_abs_path`.
fn abs_path(p: &str) -> Option<String> {
    if p.is_empty() || p.len() > 4096 {
        return None;
    }
    let mut p = p.replace('\\', "/");
    // A relative store path resolves against the working directory, like bash's
    // `p="$PWD/$p"` — the config format allows one even though nothing writes it.
    if !p.starts_with('/') && !(p.len() >= 3 && p.as_bytes()[1] == b':') {
        let cwd = std::env::current_dir().ok()?;
        p = format!("{}/{p}", cwd.to_string_lossy().replace('\\', "/"));
    }
    if p.starts_with("//") {
        return None;
    }
    let mut out: Vec<&str> = Vec::new();
    let (prefix, rest) = if p.len() >= 3
        && p.as_bytes()[1] == b':'
        && p.as_bytes()[0].is_ascii_alphabetic()
        && p.as_bytes()[2] == b'/'
    {
        (p[..2].to_ascii_lowercase(), p[2..].to_string())
    } else if p.starts_with('/') {
        (String::new(), p.clone())
    } else {
        return None; // relative paths depend on $PWD; refuse rather than guess
    };
    for part in rest.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop()?;
            }
            _ => out.push(part),
        }
    }
    let joined = out.join("/");
    Some(if joined.is_empty() {
        format!("{prefix}/")
    } else {
        format!("{prefix}/{joined}")
    })
}

/// `<base>.d` for a `.tsv` base (or `<base>.d` verbatim when it is not one).
fn store_root(base: &str) -> String {
    match base.strip_suffix(".tsv") {
        Some(stem) => format!("{stem}.d"),
        None => format!("{base}.d"),
    }
}

/// True when no existing component of `path` (including the leaf) is a symlink.
fn no_symlink_path(path: &str) -> bool {
    let native = msys_to_win(path);
    let mut cur = std::path::PathBuf::new();
    for (i, comp) in std::path::Path::new(&native).components().enumerate() {
        cur.push(comp);
        if i == 0 {
            continue; // the root/prefix itself
        }
        if let Ok(md) = std::fs::symlink_metadata(&cur) {
            if md.file_type().is_symlink() {
                return false;
            }
        }
    }
    true
}

/// The leaf may be absent; when present it must be the expected kind and not a link.
fn path_leaf_ok(path: &str, dir: bool) -> bool {
    let native = msys_to_win(path);
    match std::fs::symlink_metadata(&native) {
        Err(_) => true,
        Ok(md) => !md.file_type().is_symlink() && md.is_dir() == dir,
    }
}

fn path_parent_ok(path: &str) -> bool {
    match path.rsplit_once('/') {
        Some((parent, _)) if !parent.is_empty() => no_symlink_path(parent),
        _ => true,
    }
}

fn path_object_ok(path: &str, dir: bool) -> bool {
    path_parent_ok(path) && path_leaf_ok(path, dir)
}

/// Case-insensitive on the platforms whose filesystems are (`state_same_path`).
fn same_path(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if cfg!(any(windows, target_os = "macos")) {
        return a.eq_ignore_ascii_case(b);
    }
    false
}

// ── The per-render gate ──────────────────────────────────────────────────────

pub struct Gate {
    pub mutate: bool,
    pub cur5: Reading,
    pub cur7: Reading,
    /// The 5h reading re-cast as a burn sample row (sample second, pct, reset).
    pub burn_valid: bool,
    pub burn_samp: i64,
    pub burn_tsv: String,
    pub burn_rst: i64,
    pub burn_base: Option<String>,
    pub rl5_base: Option<String>,
    pub rl7_base: Option<String>,
    /// Post-`rl_choose` state the gauges and the projection both read.
    pub rl5: Reading,
    pub rl7: Reading,
    pub burn_window: i64,
    pub burn_trim: i64,
}

impl Gate {
    /// `state_gate`: canonicalize this render's values and store namespaces.
    pub fn new(
        fh_pct: &str,
        fh_rst: &str,
        wd_pct: &str,
        wd_rst: &str,
        now: i64,
        burn_file: &str,
        rl5h_file: &str,
        rl7d_file: &str,
        burn_window: i64,
        burn_trim: i64,
    ) -> Gate {
        let mutate = !matches!(std::env::var("CORALLINE_NO_SAMPLE"), Ok(v) if v == "1");
        let burn_window = if (60..=86400).contains(&burn_window) {
            burn_window
        } else {
            600
        };
        let burn_trim = if (1..=3000).contains(&burn_trim) {
            burn_trim
        } else {
            1500
        };

        let read = |pct_raw: &str, rst_raw: &str, ceiling: i64| -> Reading {
            let mut r = Reading::default();
            if let Some((milli, canon)) = state_pct(pct_raw) {
                r.pct = milli;
                r.canon = canon;
                if let Some(rst) = state_payload_epoch(rst_raw, 10) {
                    r.rst = rst;
                    r.valid = rst > now && rst <= now + ceiling;
                }
            }
            r
        };
        let cur5 = read(fh_pct, fh_rst, RL_MAX_5H);
        let cur7 = read(wd_pct, wd_rst, RL_MAX_7D);

        let (mut burn_valid, mut burn_samp, mut burn_tsv, mut burn_rst) =
            (false, 0, String::new(), 0);
        if cur5.valid {
            if let Some(s) = state_epoch(&now.to_string(), 12) {
                burn_valid = true;
                burn_samp = s;
                burn_tsv = format!("{}.{:03}", cur5.pct / 1000, cur5.pct % 1000);
                burn_rst = cur5.rst;
            }
        }

        // All three namespaces must canonicalize, stay distinct, and hold only
        // real (non-symlink) objects of the expected kind, or none are used.
        let mut burn_base = None;
        let mut rl5_base = None;
        let mut rl7_base = None;
        if let (Some(b), Some(f), Some(s)) = (
            abs_path(burn_file),
            abs_path(rl5h_file),
            abs_path(rl7d_file),
        ) {
            let paths = [
                (store_root(&b), true),
                (b.clone(), false),
                (store_root(&f), true),
                (f.clone(), false),
                (store_root(&s), true),
                (s.clone(), false),
            ];
            let distinct = (0..paths.len()).all(|i| {
                ((i + 1)..paths.len()).all(|j| !same_path(&paths[i].0, &paths[j].0))
            });
            let objects_ok = paths.iter().all(|(p, d)| path_object_ok(p, *d));
            if distinct && objects_ok {
                burn_base = Some(b);
                rl5_base = Some(f);
                rl7_base = Some(s);
            }
        }

        Gate {
            mutate,
            cur5,
            cur7,
            burn_valid,
            burn_samp,
            burn_tsv,
            burn_rst,
            burn_base,
            rl5_base,
            rl7_base,
            rl5: Reading::default(),
            rl7: Reading::default(),
            burn_window,
            burn_trim,
        }
    }

    /// `burn_sample`: append one canonical validated 5h row.
    pub fn burn_sample(&self) {
        if !self.mutate || !self.burn_valid {
            return;
        }
        let Some(base) = self.burn_base.as_deref() else {
            return;
        };
        let native = msys_to_win(base);
        let p = std::path::Path::new(&native);
        if let Some(parent) = p.parent() {
            if !parent.is_dir() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
            let _ = writeln!(f, "{}\t{}\t{}", self.burn_samp, self.burn_tsv, self.burn_rst);
        }
    }

    /// `rl_sample`: record this render's own reading as one dir-set entry.
    pub fn rl_sample(&self, which: u8) {
        if !self.mutate {
            return;
        }
        let (base, cur) = match which {
            5 => (self.rl5_base.as_deref(), &self.cur5),
            _ => (self.rl7_base.as_deref(), &self.cur7),
        };
        let (Some(base), true) = (base, cur.valid) else {
            return;
        };
        let root = store_root(base);
        if !path_object_ok(&root, true) {
            return;
        }
        let native_root = msys_to_win(&root);
        if !std::path::Path::new(&native_root).is_dir() {
            if std::fs::create_dir_all(&native_root).is_err() {
                return;
            }
        }
        let name = format!("{:010}_{:03}.{:03}", cur.rst, cur.pct / 1000, cur.pct % 1000);
        if limit_name(&name).is_none() {
            return;
        }
        let path = format!("{root}/{name}");
        if !no_symlink_path(&path) {
            return;
        }
        let _ = std::fs::create_dir(msys_to_win(&path));
    }

    /// `rl_latest` + `rl_choose`: read the store's current-window high-water,
    /// garbage-collect what it outranks, then apply the ownership rule.
    pub fn resolve(&mut self, which: u8, now: i64) {
        let (base, max, cur) = match which {
            5 => (self.rl5_base.clone(), RL_MAX_5H, self.cur5.clone()),
            _ => (self.rl7_base.clone(), RL_MAX_7D, self.cur7.clone()),
        };
        let mut store = Reading::default();
        if let Some(base) = base {
            store = rl_latest(&base, max, now, self.mutate);
        }
        // This session's own reading wins its own window; the store wins only
        // with a strictly newer reset, and is the sole source when we have none.
        let mut out = store;
        if cur.valid && (!out.valid || cur.rst >= out.rst) {
            out = cur;
        }
        match which {
            5 => self.rl5 = out,
            _ => self.rl7 = out,
        }
    }
}

/// `state_limit_name` → (reset, milli-percent) for one strict entry basename.
fn limit_name(name: &str) -> Option<(i64, i64)> {
    if name.len() != 18 {
        return None;
    }
    let (r, p) = name.split_at(10);
    let p = p.strip_prefix('_')?;
    if !r.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let (whole, frac) = p.split_once('.')?;
    if whole.len() != 3 || frac.len() != 3 {
        return None;
    }
    if !whole.bytes().all(|b| b.is_ascii_digit()) || !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if !(whole.as_bytes()[0] == b'0' || whole == "100") {
        return None;
    }
    let pct: i64 = whole.parse::<i64>().ok()? * 1000 + frac.parse::<i64>().ok()?;
    if pct > 100_000 {
        return None;
    }
    Some((r.parse().ok()?, pct))
}

fn dir_is_empty(path: &std::path::Path) -> bool {
    std::fs::read_dir(path).map(|mut d| d.next().is_none()).unwrap_or(false)
}

/// The store's high-water entry for the window still ahead of `now`, plus the
/// garbage collection of every entry it outranks.
fn rl_latest(base: &str, max: i64, now: i64, mutate: bool) -> Reading {
    let out = Reading::default();
    let root = store_root(base);
    if !path_object_ok(base, false) || !path_object_ok(&root, true) {
        return out;
    }
    let native_root = msys_to_win(&root);
    let Ok(rd) = std::fs::read_dir(&native_root) else {
        return out;
    };
    let cut = now + max;
    let mut entries: Vec<(String, i64, i64)> = Vec::new();
    let mut raw = 0;
    for e in rd.flatten() {
        raw += 1;
        if raw > 512 {
            return out; // an oversized store is not read at all
        }
        let name = e.file_name().to_string_lossy().to_string();
        let Some((rst, pct)) = limit_name(&name) else {
            continue;
        };
        let path = e.path();
        let is_plain_dir = std::fs::symlink_metadata(&path)
            .map(|m| m.is_dir() && !m.file_type().is_symlink())
            .unwrap_or(false);
        if !is_plain_dir || !dir_is_empty(&path) {
            continue;
        }
        entries.push((name, rst, pct));
    }
    let hi = entries
        .iter()
        .filter(|(_, rst, _)| *rst > now && *rst <= cut)
        .max_by(|a, b| a.0.cmp(&b.0))
        .cloned();
    let mut out = match &hi {
        Some((_, rst, pct)) => Reading {
            valid: true,
            pct: *pct,
            canon: format!("{:03}.{:03}", pct / 1000, pct % 1000),
            rst: *rst,
        },
        None => out,
    };
    out.valid = hi.is_some();
    if mutate {
        let hi_name = hi.as_ref().map(|(n, _, _)| n.as_str());
        for (name, _, _) in &entries {
            if Some(name.as_str()) == hi_name {
                continue;
            }
            let _ = std::fs::remove_dir(std::path::Path::new(&native_root).join(name));
        }
    }
    out
}

/// `burn_tmp_sweep`: retire trim temporaries orphaned by killed renders.
pub fn burn_tmp_sweep(base: &str) {
    let native = msys_to_win(base);
    let p = std::path::Path::new(&native);
    let (Some(parent), Some(file)) = (p.parent(), p.file_name().and_then(|s| s.to_str())) else {
        return;
    };
    let Ok(base_mtime) = std::fs::metadata(p).and_then(|m| m.modified()) else {
        return;
    };
    let Ok(rd) = std::fs::read_dir(parent) else {
        return;
    };
    let mut done = 0;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let Some(mid) = name
            .strip_prefix(&format!("{file}."))
            .and_then(|r| r.strip_suffix(".tmp"))
        else {
            continue;
        };
        if mid.is_empty() || !mid.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let path = e.path();
        let plain_file = std::fs::symlink_metadata(&path)
            .map(|m| m.is_file() && !m.file_type().is_symlink())
            .unwrap_or(false);
        let older = std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .map(|t| t < base_mtime)
            .unwrap_or(false);
        if !plain_file || !older {
            continue;
        }
        let _ = std::fs::remove_file(&path);
        done += 1;
        if done >= 128 {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pct_is_strict_and_ties_to_even() {
        assert_eq!(state_pct("41").unwrap().0, 41000);
        assert_eq!(state_pct("41.0005").unwrap().0, 41000); // .0005 → even
        assert_eq!(state_pct("41.0015").unwrap().0, 41002); // .0015 → even
        assert_eq!(state_pct("41.0006").unwrap().0, 41001);
        assert_eq!(state_pct("100").unwrap().1, "100.000");
        assert!(state_pct("100.1").is_none());
        assert!(state_pct("101").is_none());
        assert!(state_pct("-1").is_none());
        assert!(state_pct("041").is_none());
        assert!(state_pct("1e2").is_none());
    }

    #[test]
    fn epochs_reject_junk() {
        assert_eq!(state_epoch("1770000000", 10), Some(1770000000));
        assert!(state_epoch("01770000000", 10).is_none());
        assert!(state_epoch("17700000000", 10).is_none());
        assert_eq!(
            state_payload_epoch("2026-08-11T12:00:00Z", 10),
            Some(1786449600)
        );
        assert!(state_payload_epoch("2026-08-11T12:00:00+02:00", 10).is_none());
    }

    #[test]
    fn round_even_matches_bash() {
        assert_eq!(round_even(5, 2), Some(2)); // 2.5 → 2
        assert_eq!(round_even(7, 2), Some(4)); // 3.5 → 4
        assert_eq!(round_even(41500, 1000), Some(42));
        assert_eq!(round_even(42500, 1000), Some(42));
    }

    #[test]
    fn limit_names_are_exact() {
        assert_eq!(limit_name("1770000000_041.500"), Some((1770000000, 41500)));
        assert!(limit_name("1770000000_41.500").is_none());
        assert!(limit_name("1770000000_101.000").is_none());
        assert!(limit_name("1770000000_100.000").is_some());
    }
}
