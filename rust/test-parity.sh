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
SEGS="dir model ctx limit5h limit7d cost clock lines style duration"
tmp=$(mktemp -d); pass=0; fail=0
check(){ # $1=label  (reads conf on stdin into $tmp/conf, COLUMNS via $2)
  local label="$1" cols="${2:-}"
  COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" bash "$US" < "$IN" 2>/dev/null | mask > "$tmp/b"
  COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" "$EXE"      < "$IN" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$label"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$label"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}

for theme in claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night mono; do
  printf '. %s/themes/%s.conf\nVL_SEGMENTS="%s"\n' "$RT" "$theme" "$SEGS" > "$tmp/conf"
  check "theme: $theme"
done
printf '. %s/themes/claude-coral.conf\nVL_STYLE="lean"\nVL_LEAN_SEP=" "\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: lean"
printf '. %s/themes/claude-coral.conf\nVL_LAYOUT="auto"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "layout: auto wrap (COLUMNS=50)" 50
printf '. %s/themes/claude-coral.conf\nVL_ASCII=1\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "ascii mode"
printf '. %s/themes/claude-coral.conf\nVL_CLOCK="24h"\nVL_SEGMENTS="clock"\n' "$RT" > "$tmp/conf"; check "clock: 24h"

rm -rf "$tmp" "$HOME/.claude/coralline/.cache/out-native" 2>/dev/null
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
