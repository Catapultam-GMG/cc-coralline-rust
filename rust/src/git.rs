//! Git state, ported from upstream statusline.sh.
//!
//! The branch comes straight from .git/HEAD (pure file read — instant). The
//! `project` segment's stable repo-root name is derived from the git dir path
//! (no spawn). The expensive working-tree info (dirty marks +!? and ahead/behind
//! ⇡⇣) rides a cache produced in the BACKGROUND: the foreground render reads the
//! last cache and, when stale, spawns a DETACHED `coralline --git-refresh <cwd>`
//! child that runs `git status` and rewrites the cache. The render never blocks.
//!
//! (The async refresh is a native-port enhancement; OUTPUT matches upstream's
//! synchronous renderer once the cache is warm.)
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
pub struct GitInfo {
    pub branch: String,
    pub marks: String,
    pub ab: String,
    pub dirty: bool,
    pub root: String, // stable main-repo basename, for seg_project
}

fn djb2(s: &str) -> String {
    let mut h: u64 = 5381;
    for c in s.chars() {
        h = (h.wrapping_mul(33).wrapping_add(c as u64)) & 0x7fff_ffff;
    }
    format!("{:x}", h)
}

fn norm(p: &str) -> String {
    p.replace('\\', "/")
}

fn basename(p: &str) -> String {
    p.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

fn mtime(p: &Path) -> Option<u64> {
    std::fs::metadata(p)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn git_dir_of(dir: &str) -> Option<PathBuf> {
    let mut d = PathBuf::from(norm(dir));
    loop {
        let dotgit = d.join(".git");
        if dotgit.is_dir() {
            return Some(dotgit);
        }
        if dotgit.is_file() {
            let content = std::fs::read_to_string(&dotgit).ok()?;
            let first = content.lines().next().unwrap_or("");
            let p = first.strip_prefix("gitdir: ").unwrap_or(first).trim();
            let pb = PathBuf::from(norm(p));
            let is_abs = p.starts_with('/') || (p.len() >= 2 && p.as_bytes()[1] == b':');
            return Some(if is_abs { pb } else { d.join(pb) });
        }
        if !d.pop() {
            return None;
        }
    }
}

fn read_branch(gitdir: &Path) -> Option<String> {
    let head = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let head = head.trim();
    if let Some(b) = head.strip_prefix("ref: refs/heads/") {
        Some(b.to_string())
    } else if let Some(b) = head.strip_prefix("ref: ") {
        Some(b.to_string())
    } else if !head.is_empty() {
        Some(head.chars().take(7).collect())
    } else {
        None
    }
}

/// Stable main-repo basename (same in every linked worktree), like upstream's
/// `git rev-parse --git-common-dir` basename — derived from the git dir path.
fn repo_root_name(gitdir_s: &str) -> String {
    let common = if let Some(i) = gitdir_s.find("/.git/worktrees/") {
        &gitdir_s[..i]
    } else if let Some(stripped) = gitdir_s.strip_suffix("/.git") {
        stripped
    } else {
        // gitdir is itself the repo root's .git or a bare dir; use its parent.
        match gitdir_s.rsplit_once('/') {
            Some((parent, _)) => parent,
            None => gitdir_s,
        }
    };
    basename(common)
}

/// Gather git info. Reads branch from HEAD + derives the project root name;
/// loads dirty/ahead-behind from cache and kicks a background refresh when stale.
pub fn gather(cwd: &str, coralline_dir: &str, segments_use_git: bool) -> GitInfo {
    let mut gi = GitInfo::default();
    if cwd.is_empty() || !segments_use_git {
        return gi;
    }
    let gitdir = match git_dir_of(cwd) {
        Some(g) => g,
        None => return gi,
    };
    let gitdir_s = norm(&gitdir.to_string_lossy());

    gi.root = repo_root_name(&gitdir_s);
    gi.branch = read_branch(&gitdir).unwrap_or_default();
    if gi.branch.is_empty() {
        return gi;
    }

    let cache_dir = format!("{coralline_dir}/.cache/git-native");
    let _ = std::fs::create_dir_all(&cache_dir);
    let cache = PathBuf::from(format!("{}/{}", cache_dir, djb2(cwd)));

    if cache_stale(&cache, &gitdir, git_ttl()) {
        spawn_refresh(cwd);
    }
    if let Ok(content) = std::fs::read_to_string(&cache) {
        let mut it = content.lines();
        gi.marks = it.next().unwrap_or("").to_string();
        gi.ab = it.next().unwrap_or("").to_string();
        gi.dirty = it.next().unwrap_or("0") == "1";
    }
    gi
}

fn git_ttl() -> u64 {
    std::env::var("VL_GIT_TTL")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300)
}

fn cache_stale(cache: &Path, gitdir: &Path, ttl: u64) -> bool {
    let cm = match mtime(cache) {
        Some(m) => m,
        None => return true,
    };
    if now().saturating_sub(cm) >= ttl {
        return true;
    }
    if let Some(hm) = mtime(&gitdir.join("HEAD")) {
        if hm > cm {
            return true;
        }
    }
    if let Some(im) = mtime(&gitdir.join("index")) {
        if im > cm {
            return true;
        }
    }
    false
}

fn spawn_refresh(cwd: &str) {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return,
    };
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("--git-refresh").arg(cwd);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW);
    }
    let _ = cmd.spawn();
}

/// Entry point for `--git-refresh <cwd>`: single-flight via a lock dir, run
/// `git status`, parse, and atomically write the cache.
pub fn refresh(cwd: &str, coralline_dir: &str) {
    let cache_dir = format!("{coralline_dir}/.cache/git-native");
    let _ = std::fs::create_dir_all(&cache_dir);
    let key = djb2(cwd);
    let cache = PathBuf::from(format!("{cache_dir}/{key}"));
    let lock = PathBuf::from(format!("{cache_dir}/{key}.lock"));

    if std::fs::create_dir(&lock).is_err() {
        if let Some(m) = mtime(&lock) {
            if now().saturating_sub(m) > 15 {
                let _ = std::fs::remove_dir(&lock);
            }
        }
        return;
    }

    let (marks, ab, dirty) = run_status(cwd);
    let tmp = PathBuf::from(format!("{cache_dir}/{key}.tmp"));
    let body = format!("{marks}\n{ab}\n{}\n", if dirty { "1" } else { "0" });
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(&tmp, &cache);
    }
    let _ = std::fs::remove_dir(&lock);
}

fn run_status(cwd: &str) -> (String, String, bool) {
    let out = match git_status_output(cwd) {
        Some(o) => o,
        None => return (String::new(), String::new(), false),
    };
    let (mut a, mut b) = (0i64, 0i64);
    let (mut staged, mut unstaged, mut untracked) = (false, false, false);
    let mut have_oid = false;
    for line in out.lines() {
        if line.starts_with("# branch.oid ") {
            have_oid = true;
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            let mut parts = rest.split_whitespace();
            if let Some(av) = parts.next() {
                a = av.trim_start_matches('+').parse().unwrap_or(0);
            }
            if let Some(bv) = parts.next() {
                b = bv.trim_start_matches('-').parse().unwrap_or(0);
            }
        } else if line.starts_with("? ") {
            untracked = true;
        } else if line.starts_with("u ") {
            unstaged = true;
        } else if line.starts_with("1 ") || line.starts_with("2 ") {
            let bytes = line.as_bytes();
            if bytes.len() >= 4 {
                if bytes[2] != b'.' {
                    staged = true;
                }
                if bytes[3] != b'.' {
                    unstaged = true;
                }
            }
        }
    }
    if !have_oid {
        return (String::new(), String::new(), false);
    }
    let mut marks = String::new();
    if staged {
        marks.push('+');
    }
    if unstaged {
        marks.push('!');
    }
    if untracked {
        marks.push('?');
    }
    let mut ab = String::new();
    if a > 0 {
        ab.push('\u{21E1}');
        ab.push_str(&a.to_string());
    }
    if b > 0 {
        ab.push('\u{21E3}');
        ab.push_str(&b.to_string());
    }
    let dirty = !marks.is_empty();
    (marks, ab, dirty)
}

fn git_status_output(cwd: &str) -> Option<String> {
    let args = ["-C", cwd, "status", "--porcelain=v2", "--branch"];
    for git in ["git", "C:\\Program Files\\Git\\cmd\\git.exe"] {
        if let Ok(out) = std::process::Command::new(git).args(args).output() {
            if out.status.success() {
                return String::from_utf8(out.stdout).ok();
            }
        }
    }
    None
}
