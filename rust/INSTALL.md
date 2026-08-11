# coralline-rs — AI Installation Playbook

> **You are an AI coding assistant** (Claude Code or similar) and a user asked you
> to install the Rust build of coralline. Follow this playbook top to bottom.
> Don't skip the interview — letting the user pick their colors and layout is the
> whole point. This mirrors upstream's [`INSTALL.md`](../INSTALL.md); only the
> renderer artifact (a native binary) and the `settings.json` command differ.

## Overview

Installation places a binary, a theme, and a generated config, then registers the
binary in `settings.json`:

| Artifact | Destination | Purpose |
|---|---|---|
| `coralline[.exe]` | `~/bin/coralline[.exe]` (any PATH dir) | The native renderer |
| `themes/<chosen>.conf` | `~/.claude/coralline/themes/<chosen>.conf` | Color palette |
| generated config | `~/.claude/coralline.conf` | Layout + theme choices |
| `statusLine` entry | `~/.claude/settings.json` | Registers the binary |

## Step 1 — Get the binary

**Ask the user how they want the binary** (use your interactive question tool if
you have one, otherwise ask in plain text):

> Do you want me to **(A) download the prebuilt release** binary (built by CI — fastest, no
> toolchain needed), or **(B) build it locally** from source with `cargo` (needs the Rust
> toolchain, but you compile it yourself)?

Then follow the matching path. If the user has no preference, default to **(A)
download the release** — it's faster and needs no toolchain.

### Option A — Download the CI-built release

Grab the prebuilt asset for the user's platform from
<https://github.com/Catapultam-GMG/cc-coralline-rust/releases> (one archive per
platform: `linux-x86_64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64`).
Download, extract the `coralline[.exe]` binary, and place it on PATH:

```bash
# example: Linux x86_64 latest release
mkdir -p ~/bin
curl -fsSL https://github.com/Catapultam-GMG/cc-coralline-rust/releases/latest/download/cc-coralline-rust-linux-x86_64.tar.gz | tar -xz -C ~/bin
```

### Option B — Build locally from source

Needs the Rust toolchain (`rustup`):

```bash
command -v cargo || echo "MISSING: install Rust from https://rustup.rs"
git clone https://github.com/Catapultam-GMG/cc-coralline-rust
cd cc-coralline-rust/rust && cargo build --release
mkdir -p ~/bin && cp target/release/coralline* ~/bin/
```

`git` is optional (the git/project/stash segments silently disappear without it).
There is **no `jq` dependency** either way.

## Step 2 — Interview the user

Use your interactive question tool (e.g. `AskUserQuestion`); otherwise ask in
plain text. Ask these five, showing theme previews from the
[main README](../README.md) gallery so they can compare:

1. **Theme** — claude-coral · catppuccin-mocha · nord · gruvbox-dark · tokyo-night ·
   dracula · mono · reverie · lunar-pink · morning-haze
2. **Style** — `pill` (powerline), `lean` (flat p10k text), or `classic`
   (p10k's uniform dark bar)
3. **Layout** — `auto` (responsive, wraps when narrow) or `fixed` (pinned rows)
4. **Clock** — `12h` / `24h` / `off`, and seconds on/off
5. **Segments** — default `dir git model ctx limit5h limit7d cost clock`; offer
   the extras `project worktree lines style duration effort stash` (`worktree` is a
   coralline-rs addition; `effort` shows the reasoning effort level), and
   `VL_NAME_MAX` if they have long branch/repo names.

## Step 3 — Install the chosen theme

```bash
mkdir -p ~/.claude/coralline/themes
cp themes/<chosen>.conf ~/.claude/coralline/themes/
```

## Step 4 — Generate `~/.claude/coralline.conf`

Write the user's answers, sourcing the theme first:

```bash
. ~/.claude/coralline/themes/<chosen>.conf
VL_STYLE="pill"
VL_LAYOUT="auto"
VL_SEGMENTS="dir git model ctx limit5h limit7d cost clock"
VL_CLOCK="12h"
VL_CLOCK_SECONDS=1
# VL_NAME_MAX=20        # uncomment to truncate long project/branch names
# VL_CTX_GLYPH="⬡"      # swap if the terminal font renders ⬡/⬢ double-width
# VL_PROJECT_GLYPH="⬢"
# VL_CTX_ALWAYS_SHOW=1  # show an empty-but-valid context window as 0%
# VL_COST_ALWAYS_SHOW=1 # show a missing-but-valid cost as $0.00
```

If the user reports that `⬡` or `⬢` renders wide enough to shove the rest of the
row out of alignment, set `VL_CTX_GLYPH` / `VL_PROJECT_GLYPH` to characters their
font actually carries — these are plain Unicode, not Nerd Font icons, so the
terminal's own fallback decides their width.

## Step 5 — Register in `settings.json`

```json
{ "statusLine": { "type": "command", "command": "<ABSOLUTE PATH TO BINARY>", "refreshInterval": 1 } }
```

- **macOS/Linux:** use the binary path directly, e.g. `/home/you/bin/coralline`.
- **Windows:** Claude Code runs the command through a POSIX shell, so use a
  **forward-slash** path: `C:/Users/you/bin/coralline.exe` (a backslash path is
  mangled by the shell). For best spawn latency, keep the binary in a folder
  excluded from Defender real-time scanning.

## Step 6 — Verify

```bash
<BINARY> < rust/test/sample-input.json   # should print a rendered, colored line
```

If it prints a status line, you're done — Claude Code will pick it up on the next
render (or after a restart).
