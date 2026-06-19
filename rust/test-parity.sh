#!/usr/bin/env bash
# Prove the Rust binary is byte-identical to coralline's bash statusline.sh.
#
# Diffs both renderers across every theme, both styles, both layouts, ASCII mode,
# and clock variants, using upstream's test/sample-input.json. Volatile fields
# (wall-clock time, rate-limit countdowns) are masked since the two renderers run
# a moment apart. Run from the rust/ directory after `cargo build --release`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
US="$root/statusline.sh"
IN="$root/test/sample-input.json"
EXE="$here/target/release/coralline"
[ -x "$EXE" ] || EXE="$here/target/release/coralline.exe"

# Theme includes must be readable by the binary's config parser.
if command -v cygpath >/dev/null 2>&1; then RT=$(cygpath -m "$root"); else RT="$root"; fi

command -v jq  >/dev/null || { echo "need jq (for the bash oracle)"; exit 2; }
command -v perl >/dev/null || { echo "need perl (for masking)"; exit 2; }
[ -x "$EXE" ] || { echo "build first: cargo build --release"; exit 2; }

mask(){ perl -CSD -pe 's/\d{1,2}:\d{2}:\d{2}/TIME/g; s/\x{21ba}[0-9a-z]+/CD/g'; }
SEGS="dir model ctx limit5h limit7d cost clock lines style duration effort"
tmp=$(mktemp -d); pass=0; fail=0
check(){ # $1=label  (reads conf on stdin into $tmp/conf, COLUMNS via $2)
  local label="$1" cols="${2:-}"
  COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" bash "$US" < "$IN" 2>/dev/null | mask > "$tmp/b"
  COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" "$EXE"      < "$IN" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$label"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$label"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}

for theme in claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night mono dracula reverie lunar-pink; do
  printf '. %s/themes/%s.conf\nVL_SEGMENTS="%s"\n' "$RT" "$theme" "$SEGS" > "$tmp/conf"
  check "theme: $theme"
done
printf '. %s/themes/claude-coral.conf\nVL_STYLE="lean"\nVL_LEAN_SEP=" "\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: lean"
printf '. %s/themes/claude-coral.conf\nVL_LAYOUT="auto"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "layout: auto wrap (COLUMNS=50)" 50
printf '. %s/themes/claude-coral.conf\nVL_ASCII=1\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "ascii mode"
printf '. %s/themes/claude-coral.conf\nVL_CLOCK="24h"\nVL_SEGMENTS="clock"\n' "$RT" > "$tmp/conf"; check "clock: 24h"

# Display-width wrapping: a CJK + emoji path must wrap at the same point in both
# renderers. seg_len counts terminal columns (wide chars = 2), so a byte- or
# code-point count would mis-wrap here and the diff would catch it.
printf '. %s/themes/claude-coral.conf\nVL_LAYOUT="auto"\nVL_SEGMENTS="dir model ctx clock"\n' "$RT" > "$tmp/conf"
WIN='{"workspace":{"current_dir":"/home/開発/プロジェクト/日本語🎌/src"},"model":{"display_name":"Claude Fable 5"},"context_window":{"used_percentage":62.4,"total_input_tokens":1234567,"total_output_tokens":2345}}'
COLUMNS=40 CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"$WIN" 2>/dev/null | mask > "$tmp/b"
COLUMNS=40 CORALLINE_CONFIG="$tmp/conf" "$EXE"      <<<"$WIN" 2>/dev/null | mask > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "width: CJK+emoji auto-wrap (COLUMNS=40)"; pass=$((pass+1))
else printf '  ✗ %s\n' "width: CJK+emoji auto-wrap (COLUMNS=40)"; diff "$tmp/b" "$tmp/e" | head -6; fail=$((fail+1)); fi

# project segment, git-less fallback (sample cwd is not a repo here, so GIT_ROOT
# is empty for both renderers): bare `project` falls back to the dir pill, but
# `dir project` suppresses the fallback so the path renders only once.
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="project"\n' "$RT" > "$tmp/conf"; check "project: git-less fallback to dir"
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="dir project"\n' "$RT" > "$tmp/conf"; check "project: no double-dir when dir present"

# project segment, in a real repo with VL_BG_PROJECT (dracula's pink ≠ dir cyan):
# create a repo and diff bash vs rust on a cwd inside it, so the project pill's
# own background color is exercised end-to-end.
prroot=$(mktemp -d)
git init -q "$prroot/repo"
git -C "$prroot/repo" -c user.email=a@b.c -c user.name=ci commit -q --allow-empty -m init
if command -v cygpath >/dev/null 2>&1; then prp=$(cygpath -m "$prroot/repo"); else prp="$prroot/repo"; fi
printf '. %s/themes/dracula.conf\nVL_SEGMENTS="project"\n' "$RT" > "$tmp/conf"
printf '{"cwd":"%s"}' "$prp" | CORALLINE_CONFIG="$tmp/conf" bash "$US" 2>/dev/null | mask > "$tmp/b"
printf '{"cwd":"%s"}' "$prp" | CORALLINE_CONFIG="$tmp/conf" "$EXE"      2>/dev/null | mask > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "project: in-repo VL_BG_PROJECT pill"; pass=$((pass+1))
else printf '  ✗ %s\n' "project: in-repo VL_BG_PROJECT pill"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
rm -rf "$prroot"

# Feature check (NO upstream oracle — the worktree segment is a coralline-rs
# extension): create a real linked worktree and assert its ⑂ pill renders.
wtroot=$(mktemp -d)
git init -q "$wtroot/repo"
git -C "$wtroot/repo" -c user.email=a@b.c -c user.name=ci commit -q --allow-empty -m init
git -C "$wtroot/repo" worktree add -q "$wtroot/feature-x" -b feature-x >/dev/null 2>&1
if command -v cygpath >/dev/null 2>&1; then wtp=$(cygpath -m "$wtroot/feature-x"); else wtp="$wtroot/feature-x"; fi
printf 'VL_SEGMENTS="worktree"\n' > "$tmp/conf"
got=$(printf '{"cwd":"%s"}' "$wtp" | CORALLINE_CONFIG="$tmp/conf" "$EXE" 2>/dev/null)
if printf '%s' "$got" | grep -q 'feature-x'; then
  printf '  ✓ %s\n' "feature: worktree segment"; pass=$((pass+1))
else
  printf '  ✗ %s\n' "feature: worktree segment"; printf '%s' "$got" | cat -v | head -1; fail=$((fail+1))
fi
rm -rf "$wtroot"

rm -rf "$tmp" "$HOME/.claude/coralline/.cache/out-native" 2>/dev/null
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
