//! Configuration: built-in defaults (mirroring upstream statusline.sh + the
//! claude-coral theme) overridden by the user's bash config file. We don't run
//! bash — we read the conf as simple `KEY=VALUE` assignments and follow one
//! level of `. include` / `source include` (used to pull in the theme file),
//! which is all coralline's conf format actually uses.
use std::path::{Path, PathBuf};

pub struct Config {
    pub style: String,
    pub lean_sep: String,
    pub lean_fg: String,
    pub layout: String,
    pub max_lines: i64,
    pub wrap_margin: i64,
    pub segments: String,
    pub segments2: String,
    pub segments3: String,
    pub bar_width: i64,
    pub bar_fill: String,
    pub bar_empty: String,
    pub clock: String,
    pub clock_seconds: bool,
    pub path_depth: i64,
    pub name_max: i64,
    pub cost_decimals: usize,
    pub warn_pct: i64,
    pub hot_pct: i64,
    pub ascii: bool,
    pub cap_l: String,
    pub cap_r: String,
    pub sep: String,
    pub git_ttl: i64,
    pub bg_dir: String,
    pub bg_git_ok: String,
    pub bg_git_dirty: String,
    pub bg_model: String,
    pub bg_ctx: String,
    pub bg_5h: String,
    pub bg_7d: String,
    pub bg_cost: String,
    pub bg_clock: String,
    pub bg_lines: String,
    pub bg_style: String,
    pub bg_duration: String,
    pub fg_text: String,
    pub fg_dim: String,
    pub fg_ok: String,
    pub fg_warn: String,
    pub fg_hot: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            style: "pill".into(),
            lean_sep: "".into(),
            lean_fg: "".into(),
            layout: "fixed".into(),
            max_lines: 3,
            wrap_margin: 4,
            segments: "dir git model ctx limit5h limit7d cost clock".into(),
            segments2: "".into(),
            segments3: "".into(),
            bar_width: 5,
            bar_fill: "▰".into(),
            bar_empty: "▱".into(),
            clock: "12h".into(),
            clock_seconds: true,
            path_depth: 4,
            name_max: 0,
            cost_decimals: 2,
            warn_pct: 50,
            hot_pct: 75,
            ascii: false,
            cap_l: "\u{E0B6}".into(),
            cap_r: "\u{E0B4}".into(),
            sep: "\u{E0B0}".into(),
            git_ttl: 300,
            bg_dir: "81,166,199".into(),
            bg_git_ok: "65".into(),
            bg_git_dirty: "130".into(),
            bg_model: "173".into(),
            bg_ctx: "238".into(),
            bg_5h: "237".into(),
            bg_7d: "236".into(),
            bg_cost: "212,125,145".into(),
            bg_clock: "70,80,110".into(),
            bg_lines: "240".into(),
            bg_style: "96".into(),
            bg_duration: "60".into(),
            fg_text: "231".into(),
            fg_dim: "245".into(),
            fg_ok: "114".into(),
            fg_warn: "179".into(),
            fg_hot: "167".into(),
        }
    }
}

impl Config {
    pub fn load(home: &str) -> Config {
        let mut c = Config::default();
        let conf = std::env::var("CORALLINE_CONFIG")
            .ok()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(format!("{home}/.claude/coralline.conf")));
        c.apply_file(&conf, home, 0);
        c.post();
        c
    }

    fn apply_file(&mut self, path: &Path, home: &str, depth: u8) {
        if depth > 4 {
            return;
        }
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => return,
        };
        for raw in text.lines() {
            let line = match raw.find('#') {
                Some(i) => &raw[..i],
                None => raw,
            };
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let inc = line
                .strip_prefix(". ")
                .or_else(|| line.strip_prefix("source "))
                .map(str::trim);
            if let Some(incpath) = inc {
                let expanded = expand(incpath, home);
                self.apply_file(Path::new(&expanded), home, depth + 1);
                continue;
            }
            if let Some(eq) = line.find('=') {
                let key = line[..eq].trim();
                let val = unquote(line[eq + 1..].trim());
                self.set(key, &val);
            }
        }
    }

    fn set(&mut self, key: &str, val: &str) {
        let v = val.to_string();
        match key {
            "VL_STYLE" => self.style = v,
            "VL_LEAN_SEP" => self.lean_sep = v,
            "VL_LEAN_FG" => self.lean_fg = v,
            "VL_LAYOUT" => self.layout = v,
            "VL_MAX_LINES" => self.max_lines = v.parse().unwrap_or(self.max_lines),
            "VL_WRAP_MARGIN" => self.wrap_margin = v.parse().unwrap_or(self.wrap_margin),
            "VL_SEGMENTS" => self.segments = v,
            "VL_SEGMENTS2" => self.segments2 = v,
            "VL_SEGMENTS3" => self.segments3 = v,
            "VL_BAR_WIDTH" => self.bar_width = v.parse().unwrap_or(self.bar_width),
            "VL_BAR_FILL" => self.bar_fill = v,
            "VL_BAR_EMPTY" => self.bar_empty = v,
            "VL_CLOCK" => self.clock = v,
            "VL_CLOCK_SECONDS" => self.clock_seconds = v == "1",
            "VL_PATH_DEPTH" => self.path_depth = v.parse().unwrap_or(self.path_depth),
            "VL_NAME_MAX" => self.name_max = v.parse().unwrap_or(self.name_max),
            "VL_COST_DECIMALS" => self.cost_decimals = v.parse().unwrap_or(self.cost_decimals),
            "VL_WARN_PCT" => self.warn_pct = v.parse().unwrap_or(self.warn_pct),
            "VL_HOT_PCT" => self.hot_pct = v.parse().unwrap_or(self.hot_pct),
            "VL_ASCII" => self.ascii = v == "1",
            "VL_GIT_TTL" => self.git_ttl = v.parse().unwrap_or(self.git_ttl),
            "VL_CAP_L" => self.cap_l = v,
            "VL_CAP_R" => self.cap_r = v,
            "VL_SEP" => self.sep = v,
            "VL_BG_DIR" => self.bg_dir = v,
            "VL_BG_GIT_OK" => self.bg_git_ok = v,
            "VL_BG_GIT_DIRTY" => self.bg_git_dirty = v,
            "VL_BG_MODEL" => self.bg_model = v,
            "VL_BG_CTX" => self.bg_ctx = v,
            "VL_BG_5H" => self.bg_5h = v,
            "VL_BG_7D" => self.bg_7d = v,
            "VL_BG_COST" => self.bg_cost = v,
            "VL_BG_CLOCK" => self.bg_clock = v,
            "VL_BG_LINES" => self.bg_lines = v,
            "VL_BG_STYLE" => self.bg_style = v,
            "VL_BG_DURATION" => self.bg_duration = v,
            "VL_FG_TEXT" => self.fg_text = v,
            "VL_FG_DIM" => self.fg_dim = v,
            "VL_FG_OK" => self.fg_ok = v,
            "VL_FG_WARN" => self.fg_warn = v,
            "VL_FG_HOT" => self.fg_hot = v,
            _ => {}
        }
    }

    fn post(&mut self) {
        if self.ascii {
            self.cap_l.clear();
            self.cap_r.clear();
            self.sep.clear();
            self.bar_fill = "#".into();
            self.bar_empty = "-".into();
        }
        if self.style == "lean" {
            self.cap_l.clear();
            self.cap_r.clear();
            self.fg_text = self.lean_fg.clone();
        }
    }
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() >= 2
        && ((b[0] == b'"' && b[b.len() - 1] == b'"') || (b[0] == b'\'' && b[b.len() - 1] == b'\''))
    {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}

fn expand(s: &str, home: &str) -> String {
    let s = s.trim();
    let p = if let Some(rest) = s.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else if s == "~" {
        home.to_string()
    } else if let Some(rest) = s.strip_prefix("$HOME/") {
        format!("{home}/{rest}")
    } else {
        s.to_string()
    };
    msys_to_win(&p)
}

/// Convert an MSYS absolute path (/c/Users/…) to a Windows one (c:/Users/…) so
/// std::fs can read it — a config might `. /c/...` instead of using ~. Windows
/// only: on Linux/macOS `/x/...` is a legitimate native path, so leave it alone.
#[cfg(windows)]
fn msys_to_win(p: &str) -> String {
    let b = p.as_bytes();
    if b.len() >= 3 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b'/' {
        format!("{}:{}", &p[1..2], &p[2..])
    } else {
        p.to_string()
    }
}

#[cfg(not(windows))]
fn msys_to_win(p: &str) -> String {
    p.to_string()
}
