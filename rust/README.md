# coralline-rs — coralline, rewritten in Rust 🦀

A single self-contained native binary that is **byte-identical in output** to
coralline's bash [`statusline.sh`](../statusline.sh) — same segments (including
`node`/`python`, `burn`, and cross-session limit sync), themes, styles (pill,
lean, classic), layouts, glyphs, escape codes, and the same `--subagent`
panel-row protocol. Just faster to spawn and dependency-free.

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

`test-parity.sh` diffs this binary against the bash renderer across every theme,
all three styles (pill/lean/classic), both layouts, ASCII mode, the clock
variants, the `node`/`python`/`burn` segments, cross-session limit sync
(including shared-store interop: each renderer reads state the other wrote, and
the burn-file trim rewrite is compared byte-for-byte), the glyph overrides,
`VL_CTX_ALWAYS_SHOW` / `VL_COST_ALWAYS_SHOW`, the elapsed-window and
store-only limit fallbacks, and `--subagent` panel rows (including the themed
name-pill inks and the fingerprint checks that withdraw them), using upstream's
own `test/sample-input.json`. Volatile fields (wall-clock, rate-limit
countdowns) are masked. Run it:

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

That includes the 2026-08 upstream knobs: `VL_CTX_GLYPH` / `VL_PROJECT_GLYPH`
(swap the plain-Unicode `⬡`/`⬢` for characters your terminal font carries),
`VL_CTX_ALWAYS_SHOW` / `VL_COST_ALWAYS_SHOW` (render an empty-but-valid reading
as `0%` / `$0.00` instead of hiding the segment), and the themed subagent
name pill (`VL_BG_SUB_NAME` plus the `VL_FG_SUB_TEXT` / `_OK` / `_HOT` / `_DIM`
status inks, adopted from a theme's candidates only while the palette they were
solved against is intact). The burn and rate-limit stores use upstream's
canonical on-disk format, so both renderers can share one state directory.

## Beyond upstream

Additive features not in upstream coralline (inert by default, so output stays
byte-identical until you opt in):

- **`worktree` segment** — when you're in a linked git worktree, shows its name as
  its own `⑂` pill (background `VL_BG_WT`). Compose with `project` (stable repo-root
  name) and `dir`, e.g. `VL_SEGMENTS="project worktree dir git …"`. Hidden in the
  main worktree / outside a repo. `test-parity.sh` has a dedicated check for it
  (there's no upstream output to diff against).

- **`VL_PROJECT_ROOTS`** — a comma/semicolon list of project-root prefixes (e.g.
  `VL_PROJECT_ROOTS="D:/GitHub;C:/work"`) that the `dir` segment strips so deep
  repo paths render relative to their root, marked with a `⌂` house glyph
  (suppressed under `VL_ASCII=1`). `$HOME`→`~` collapsing still takes precedence;
  depth elision (`VL_PATH_DEPTH`) still applies to the shortened result. Unset by
  default → `dir` stays byte-identical to bash.

- **Native float carrier** — the float readout (`VL_FLOAT=1`, writing
  `VL_FLOAT_FILE`) is emitted by the binary just like upstream's bash. The example
  iTerm2 carrier in [`../example/float-display-iterm2/`](../example/float-display-iterm2/)
  is also built into the binary: run `coralline --float-carrier` (loop, clears the
  bar on exit) or `coralline --float-carrier --once` from an interactive shell, no
  bash dependency. Honors the same `CORALLINE_FLOAT_FILE` / `_INTERVAL` / `_STALE`
  / `_TTY` env knobs as the script.

## Credits

A port of [coralline](https://github.com/Nanako0129/coralline) by Nanako0129,
whose visual style is a tribute to
[powerlevel10k](https://github.com/romkatv/powerlevel10k).
