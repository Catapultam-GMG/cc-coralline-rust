//! `coralline --float-carrier` — transports the plain-text float readout
//! (written by the renderer to VL_FLOAT_FILE) to iTerm2's status bar via a
//! `SetUserVar` OSC on the controlling tty. A faithful Rust port of the example
//! `coralline-float` bash carrier.
//!
//! It is deliberately dumb: NO formatting logic — the renderer is the single
//! source of visual truth; this only carries the bytes. Claude Code sanitizes
//! control sequences out of statusline output and its spawned processes have no
//! usable tty, so this must run from an interactive shell whose tty it inherits.
//!
//! Honors the same env knobs as the bash carrier so the shared tests apply:
//!   CORALLINE_FLOAT_FILE, CORALLINE_FLOAT_INTERVAL, CORALLINE_FLOAT_STALE,
//!   CORALLINE_FLOAT_TTY.
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static STOP: AtomicBool = AtomicBool::new(false);

fn env_or(name: &str, default: &str) -> String {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

fn home() -> String {
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return h;
        }
    }
    std::env::var("USERPROFILE").unwrap_or_else(|_| ".".into())
}

fn float_file() -> PathBuf {
    let def = format!("{}/.claude/coralline/float.txt", home());
    PathBuf::from(env_or("CORALLINE_FLOAT_FILE", &def))
}

/// Standard base64 with padding (RFC 4648), matching `base64` from coreutils.
fn b64(input: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[(n >> 18 & 63) as usize] as char);
        out.push(T[(n >> 12 & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6 & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// Resolve the target tty path. CORALLINE_FLOAT_TTY overrides (tests / advanced
/// setups); otherwise the controlling tty on Unix, which must be a real device.
fn resolve_tty() -> Option<String> {
    if let Ok(t) = std::env::var("CORALLINE_FLOAT_TTY") {
        if !t.is_empty() {
            return Some(t);
        }
    }
    #[cfg(unix)]
    {
        // The controlling terminal. Require it to be a char device, mirroring the
        // bash carrier's `case "$TTY" in /dev/*`.
        let p = "/dev/tty";
        if std::path::Path::new(p).exists() {
            return Some(p.to_string());
        }
        None
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// Write a SetUserVar OSC carrying `value` (empty clears the bar). Truncate-write
/// so a regular file (tests) holds exactly one OSC; on a tty it's a plain write.
fn emit(tty: &str, value: &str) {
    let osc = format!("\x1b]1337;SetUserVar=coralline={}\x07", b64(value.as_bytes()));
    if let Ok(mut f) = OpenOptions::new().write(true).create(true).truncate(true).open(tty) {
        let _ = f.write_all(osc.as_bytes());
    }
}

/// The value to push: file contents if fresh, empty if stale/missing. Trailing
/// newlines are trimmed to match the bash carrier's `$(...)` capture.
fn current_value(file: &std::path::Path, stale: u64) -> String {
    let meta = match std::fs::metadata(file) {
        Ok(m) => m,
        Err(_) => return String::new(),
    };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs());
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match mtime {
        Some(mt) if now.saturating_sub(mt) <= stale => match std::fs::read_to_string(file) {
            Ok(s) => s.trim_end_matches(['\n', '\r']).to_string(),
            Err(_) => String::new(),
        },
        _ => String::new(),
    }
}

#[cfg(unix)]
fn install_stop() {
    extern "C" fn on_sig(_sig: i32) {
        STOP.store(true, Ordering::SeqCst);
    }
    extern "C" {
        fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
    }
    // SIGINT=2, SIGHUP=1, SIGTERM=15
    unsafe {
        signal(2, on_sig);
        signal(1, on_sig);
        signal(15, on_sig);
    }
}

#[cfg(windows)]
fn install_stop() {
    extern "system" fn on_ctrl(_ctrl_type: u32) -> i32 {
        STOP.store(true, Ordering::SeqCst);
        1 // handled
    }
    extern "system" {
        fn SetConsoleCtrlHandler(handler: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
    }
    unsafe {
        SetConsoleCtrlHandler(Some(on_ctrl), 1);
    }
}

#[cfg(not(any(unix, windows)))]
fn install_stop() {}

/// Entry point for `--float-carrier`. With `once`, emit a single iteration and
/// exit (tests / scripted use). Otherwise poll, dedupe writes, clear on exit.
pub fn carrier(once: bool) {
    let tty = match resolve_tty() {
        Some(t) => t,
        None => {
            eprintln!(
                "coralline --float-carrier: no controlling tty \
                 (launch from an interactive shell, or set CORALLINE_FLOAT_TTY)"
            );
            std::process::exit(1);
        }
    };
    let file = float_file();
    let interval: u64 = env_or("CORALLINE_FLOAT_INTERVAL", "1").parse().unwrap_or(1);
    let stale: u64 = env_or("CORALLINE_FLOAT_STALE", "5").parse().unwrap_or(5);

    if once {
        emit(&tty, &current_value(&file, stale));
        return;
    }

    install_stop();
    // Sentinel that no real value equals, so the first push always fires.
    let mut last = String::from("\u{1}");
    while !STOP.load(Ordering::SeqCst) {
        let val = current_value(&file, stale);
        if val != last {
            emit(&tty, &val);
            last = val;
        }
        std::thread::sleep(Duration::from_secs(interval.max(1)));
    }
    emit(&tty, ""); // clear the bar on exit
}
