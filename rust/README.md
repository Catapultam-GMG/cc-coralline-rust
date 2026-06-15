# coralline-rs — coralline, rewritten in Rust 🦀

A single self-contained native binary that is **byte-identical in output** to
coralline's bash [`statusline.sh`](../statusline.sh) — same segments, themes,
styles, layouts, glyphs, escape codes. Just faster to spawn and dependency-free.

## Why

The bash renderer spawns `bash` + `jq` + a `git` subprocess on every render. On
most systems that's fine. On Windows (Git Bash / MSYS) every process spawn is
expensive — antivirus scans each executable launch and the fork is emulated — so
a render can take **1–5 s**, and the cost multiplies across parallel sessions at
`refreshInterval: 1`. A native binary spawns in **~10 ms** (≈ `cmd /c exit`),
needs **no `jq`**, and parses JSON + renders in well under a millisecond.

| | bash `statusline.sh` | `coralline.exe` |
|---|---|---|
| Deps | `bash`, `jq`, `git` | none (git optional) |
| Spawn cost (Windows) | ~1–5 s under load | ~10 ms |
| Output | — | **byte-identical** |

## Parity

`test-parity.sh` diffs this binary against the bash renderer across all 6 themes,
both styles, both layouts, ASCII mode, and the clock variants, using upstream's
own `test/sample-input.json`. Volatile fields (wall-clock, rate-limit countdowns)
are masked. Run it:

```bash
./test-parity.sh            # from the rust/ directory
```

This same diff runs on **Linux and Windows in CI** (`.github/workflows/rust-parity.yml`)
on every push, so parity is verified on both. Cross-platform: Windows uses
`GetLocalTime`, Linux/macOS use libc `localtime_r` for the clock — both matching
bash's `date`.

## Build & install

```bash
cargo build --release
# install somewhere on PATH (or reference the full path in settings.json)
cp target/release/coralline ~/bin/coralline            # macOS/Linux
# cp target/release/coralline.exe ~/bin/coralline.exe  # Windows
```

Register it in `~/.claude/settings.json` (same contract as the bash version —
JSON on stdin, status line on stdout):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/home/you/bin/coralline",
    "refreshInterval": 1
  }
}
```

> **Windows note:** Claude Code runs the statusline command through a POSIX shell
> (Git Bash), which eats backslashes — use a **forward-slash** path:
> `"command": "C:/Users/you/bin/coralline.exe"`. For best spawn latency, put the
> binary in a folder excluded from Windows Defender real-time scanning.

## Configuration & themes

Identical to upstream — it reads the same `~/.claude/coralline.conf` (and its
`. include` of a theme file) and the same `VL_*` variables. See the
[main README](../README.md) for the full configuration reference and theme
gallery, and [`INSTALL.md`](INSTALL.md) for the guided (AI-agent) installer.

## Beyond upstream

One additive segment not in upstream coralline:

- **`worktree`** — when you're in a linked git worktree, shows its name as its own
  `⑂` pill (background `VL_BG_WT`). Compose with `project` (stable repo-root name)
  and `dir`, e.g. `VL_SEGMENTS="project worktree dir git …"`. Hidden in the main
  worktree / outside a repo. `test-parity.sh` includes a dedicated check for it
  (there's no upstream output to diff against).

## Credits

A port of [coralline](https://github.com/Nanako0129/coralline) by Nanako0129,
whose visual style is a tribute to
[powerlevel10k](https://github.com/romkatv/powerlevel10k).
