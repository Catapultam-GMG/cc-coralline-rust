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

for theme in claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night mono dracula reverie lunar-pink morning-haze; do
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

# ── Forward-ported upstream features ────────────────────────────────────────
# checkp: like check() but with an explicit payload and optional extra env
# (NAME=value pairs before the label). Both renderers get identical env/state.
checkp() { # $1=label $2=payload [$3=cols] [$4...=env pairs]
  local label="$1" payload="$2" cols="${3:-}"; shift; shift; [ $# -gt 0 ] && shift
  env "$@" COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"$payload" 2>/dev/null | mask > "$tmp/b"
  env "$@" COLUMNS="$cols" CORALLINE_CONFIG="$tmp/conf" "$EXE"      <<<"$payload" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$label"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$label"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}

# classic style + lean uniform background / caps
printf '. %s/themes/claude-coral.conf\nVL_STYLE="classic"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: classic"
printf '. %s/themes/mono.conf\nVL_STYLE="classic"\nVL_BG_BAR="30,30,46"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: classic custom VL_BG_BAR"
printf '. %s/themes/claude-coral.conf\nVL_STYLE="classic"\nVL_ASCII=1\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: classic ascii"
printf '. %s/themes/claude-coral.conf\nVL_STYLE="lean"\nVL_LEAN_SEP=" "\nVL_LEAN_BG="238"\nVL_LEAN_CAP_L="<"\nVL_LEAN_CAP_R=">"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: lean bg + caps"
printf '. %s/themes/claude-coral.conf\nVL_STYLE="classic"\nVL_LAYOUT="auto"\nVL_SEGMENTS="%s"\n' "$RT" "$SEGS" > "$tmp/conf"; check "style: classic auto wrap (COLUMNS=50)" 50

# node / python runtime segments (pin files walking up from cwd; venv env)
rtroot=$(mktemp -d); mkdir -p "$rtroot/proj/sub"
printf 'v22.1.0\n' > "$rtroot/proj/.nvmrc"
printf '3.12.4\n'  > "$rtroot/proj/sub/.python-version"
if command -v cygpath >/dev/null 2>&1; then rtp=$(cygpath -m "$rtroot/proj/sub"); else rtp="$rtroot/proj/sub"; fi
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="node python model"\n' "$RT" > "$tmp/conf"
checkp "runtime: node+python pin files" "{\"cwd\":\"$rtp\",\"model\":{\"display_name\":\"Claude Fable 5\"}}"
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="python"\n' "$RT" > "$tmp/conf"
checkp "runtime: VIRTUAL_ENV basename" "{\"cwd\":\"$rtp\"}" "" VIRTUAL_ENV=/opt/venvs/myproj
checkp "runtime: conda env (base hidden)" "{\"cwd\":\"$rtp\"}" "" CONDA_DEFAULT_ENV=base VIRTUAL_ENV=
printf '. %s/themes/claude-coral.conf\nVL_ASCII=1\nVL_SEGMENTS="node python"\n' "$RT" > "$tmp/conf"
checkp "runtime: ascii glyphs" "{\"cwd\":\"$rtp\"}"
rm -rf "$rtroot"

# cross-session limit sync (dir-set high-water store)
lsd=$(mktemp -d); NOWT=$(date +%s)
if command -v cygpath >/dev/null 2>&1; then lsp=$(cygpath -m "$lsd"); else lsp="$lsd"; fi
seed_store() {  # fresh store: one real high-water + one poisoned sentinel per window
  rm -rf "$lsd/limit-5h.d" "$lsd/limit-7d.d"
  mkdir -p "$lsd/limit-5h.d/$(printf '%010d_%07.3f' $((NOWT+3600))  55.5)"
  mkdir -p "$lsd/limit-5h.d/$(printf '%010d_%07.3f' $((NOWT+3600))  41.25)"
  mkdir -p "$lsd/limit-5h.d/$(printf '%010d_%07.3f' 1900000000 99)"        # 2030 sentinel → pruned
  mkdir -p "$lsd/limit-7d.d/$(printf '%010d_%07.3f' $((NOWT+300000)) 12)"
}
printf '. %s/themes/claude-coral.conf\nVL_LIMIT_SYNC=1\nVL_SEGMENTS="limit5h limit7d"\n' "$RT" > "$tmp/conf"
LPAY="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":$((NOWT+3600))},\"seven_day\":{\"used_percentage\":10,\"resets_at\":$((NOWT+300000))}}}"
seed_store
env CORALLINE_RL5H_FILE="$lsp/limit-5h.tsv" CORALLINE_RL7D_FILE="$lsp/limit-7d.tsv" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"$LPAY" 2>/dev/null | mask > "$tmp/b"
seed_store
env CORALLINE_RL5H_FILE="$lsp/limit-5h.tsv" CORALLINE_RL7D_FILE="$lsp/limit-7d.tsv" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$tmp/conf" "$EXE" <<<"$LPAY" 2>/dev/null | mask > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "limit sync: high-water + sentinel prune"; pass=$((pass+1))
else printf '  ✗ %s\n' "limit sync: high-water + sentinel prune"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
# write path: sampling on → this render's own 62% becomes the high-water
seed_store
env CORALLINE_RL5H_FILE="$lsp/limit-5h.tsv" CORALLINE_RL7D_FILE="$lsp/limit-7d.tsv" \
  CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"${LPAY/40/62.4}" 2>/dev/null | mask > "$tmp/b"
seed_store
env CORALLINE_RL5H_FILE="$lsp/limit-5h.tsv" CORALLINE_RL7D_FILE="$lsp/limit-7d.tsv" \
  CORALLINE_CONFIG="$tmp/conf" "$EXE" <<<"${LPAY/40/62.4}" 2>/dev/null | mask > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "limit sync: own sample wins"; pass=$((pass+1))
else printf '  ✗ %s\n' "limit sync: own sample wins"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
rm -rf "$lsd"

# burn segment (range-to-empty): active / warming / idle / all-good / 7d binding
bt=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then btp=$(cygpath -m "$bt"); else btp="$bt"; fi
BRST=$((NOWT+7200))
BPAY="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$BRST},\"seven_day\":{\"used_percentage\":50,\"resets_at\":$((NOWT+302400))}}}"
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="burn"\n' "$RT" > "$tmp/conf"
burncheck() { # $1=label $2=payload
  env CORALLINE_BURN_FILE="$btp/burn-5h.tsv" CORALLINE_NO_SAMPLE=1 \
    CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"$2" 2>/dev/null | mask > "$tmp/b"
  env CORALLINE_BURN_FILE="$btp/burn-5h.tsv" CORALLINE_NO_SAMPLE=1 \
    CORALLINE_CONFIG="$tmp/conf" "$EXE" <<<"$2" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$1"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}
: > "$btp/burn-5h.tsv"                                     # no samples yet
burncheck "burn: warming (no samples)" "$BPAY"
for i in 0 1 2 3 4 5; do                                   # steady climb → active ETA
  printf '%s\t%s\t%s\n' $((NOWT-300+i*60)) $((40+i*3)) "$BRST"
done > "$btp/burn-5h.tsv"
burncheck "burn: active 5h ETA" "$BPAY"
for i in 0 1 2 3 4 5; do                                   # crossings, all outside window
  printf '%s\t%s\t%s\n' $((NOWT-2000+i*60)) $((40+i*3)) "$BRST"
done > "$btp/burn-5h.tsv"
burncheck "burn: idle (stopped burning)" "$BPAY"
printf '%s\t40\t%s\n%s\t41\t%s\n%s\t42\t%s\n' \
  $((NOWT-590)) "$BRST" $((NOWT-560)) "$BRST" $((NOWT-10)) "$BRST" > "$btp/burn-5h.tsv"
burncheck "burn: all-good check (eta > window)" "$BPAY"
: > "$btp/burn-5h.tsv"                                     # 7d binds when 5h has no slope
burncheck "burn: 7d stateless binding" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":$((NOWT+302400))}}}"
rm -rf "$bt"

# --subagent panel mode
sa=$(mktemp -d); mkdir -p "$sa/sess/subagents"
printf '{"agentType":"scout","x":1}\n' > "$sa/sess/subagents/agent-task-1.meta.json"
if command -v cygpath >/dev/null 2>&1; then sap=$(cygpath -m "$sa"); else sap="$sa"; fi
SPAY="{\"transcript_path\":\"$sap/sess.jsonl\",\"columns\":100,\"tasks\":[
 {\"id\":\"task-1\",\"type\":\"local_agent\",\"label\":\"Explore config sources\",\"status\":\"running\",\"model\":\"claude-haiku-4-5-20251001\",\"contextWindowSize\":200000,\"tokenCount\":42000},
 {\"id\":\"task-2\",\"name\":\"big-refactor\",\"type\":\"local_agent\",\"label\":\"Refactor renderer\",\"status\":\"completed\",\"model\":\"claude-fable-5\",\"contextWindowSize\":200000,\"tokenCount\":155000},
 {\"id\":\"task-3\",\"type\":\"local_agent\",\"label\":\"just-spawned\",\"status\":\"queued\"},
 {\"id\":\"task-4\",\"label\":\"gateway\",\"status\":\"failed\",\"model\":\"gpt-5.6-luna\",\"tokenCount\":1234}
]}"
subcheck() { # $1=label $2=payload [$3=maskexpr]
  local m="${3:-cat}"
  bash "$US" --subagent <<<"$2" 2>/dev/null | eval "$m" > "$tmp/b"
  "$EXE" --subagent <<<"$2" 2>/dev/null | eval "$m" > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$1"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}
printf '. %s/themes/claude-coral.conf\nVL_SUB_SEGMENTS="name model ctx"\n' "$RT" > "$tmp/conf"
export CORALLINE_CONFIG="$tmp/conf"
subcheck "subagent: rows (name model ctx) + sidecar role" "$SPAY"
printf '. %s/themes/claude-coral.conf\nVL_STYLE="classic"\nVL_SUB_SEGMENTS="name model ctx"\nVL_NAME_MAX=14\n' "$RT" > "$tmp/conf"
subcheck "subagent: classic rows + VL_NAME_MAX" "$SPAY"
printf '. %s/themes/claude-coral.conf\n' "$RT" > "$tmp/conf"
SPAY2="{\"tasks\":[{\"id\":\"e1\",\"label\":\"timed\",\"status\":\"running\",\"startTime\":$(( (NOWT-3725) * 1000 ))}]}"
subcheck "subagent: elapsed (seconds masked)" "$SPAY2" "sed -E 's/(⧖ [0-9]+h[0-9]+m)[0-9]+s/\\1XXs/'"
subcheck "subagent: concatenated docs → last wins" "{\"tasks\":[{\"id\":\"old\",\"label\":\"stale\",\"status\":\"running\"}]}${SPAY}"
subcheck "subagent: empty tasks → no output" "{\"tasks\":[]}"
# The name pill's status inks are adopted only while the palette (and, in the
# styles that paint one, the bar) is still the one they were solved against.
printf '. %s/themes/claude-coral.conf\nVL_SUB_SEGMENTS="name"\nVL_FG_OK="0,0,0"\n' "$RT" > "$tmp/conf"
subcheck "subagent: a retinted palette keeps its own inks" "$SPAY"
printf '. %s/themes/claude-coral.conf\nVL_SUB_SEGMENTS="name"\nVL_BG_SUB_NAME=""\n' "$RT" > "$tmp/conf"
subcheck "subagent: explicit VL_BG_SUB_NAME restores the light pill" "$SPAY"
printf '. %s/themes/claude-coral.conf\nVL_SUB_SEGMENTS="name"\nVL_STYLE="lean"\n' "$RT" > "$tmp/conf"
subcheck "subagent: bare lean bows out of the pill inks" "$SPAY"
printf '. %s/themes/morning-haze.conf\nVL_SUB_SEGMENTS="name model ctx"\n' "$RT" > "$tmp/conf"
subcheck "subagent: morning-haze theme candidates" "$SPAY"
unset CORALLINE_CONFIG
rm -rf "$sa"

# cross-renderer state interop: bash WRITES the stores, rust READS them (and
# vice versa for burn) — proves both speak the same on-disk format.
ix=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then ixp=$(cygpath -m "$ix"); else ixp="$ix"; fi
printf '. %s/themes/claude-coral.conf\nVL_LIMIT_SYNC=1\nVL_SEGMENTS="limit5h"\n' "$RT" > "$tmp/conf"
IXPAY5="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":62.4,\"resets_at\":$((NOWT+3600))}}}"
env CORALLINE_RL5H_FILE="$ixp/limit-5h.tsv" CORALLINE_CONFIG="$tmp/conf" \
  bash "$US" <<<"$IXPAY5" >/dev/null 2>&1                      # bash records 62.4
# A session with no reading of its own takes the store as its sole source, so
# this is the read path both renderers have to agree on byte-for-byte.
env CORALLINE_RL5H_FILE="$ixp/limit-5h.tsv" CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$tmp/conf" \
  bash "$US" <<<'{}' 2>/dev/null | mask > "$tmp/b"
env CORALLINE_RL5H_FILE="$ixp/limit-5h.tsv" CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$tmp/conf" \
  "$EXE" <<<'{}' 2>/dev/null | mask > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null && grep -q '62' "$tmp/e"; then
  printf '  ✓ %s\n' "interop: rust reads bash-written rl store"; pass=$((pass+1))
else printf '  ✗ %s\n' "interop: rust reads bash-written rl store"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="burn"\n' "$RT" > "$tmp/conf"
for i in 0 1 2 3 4; do printf '%s\t%s\t%s\n' $((NOWT-300+i*60)) $((40+i*3)) $((NOWT+7200)); done > "$ix/burn-5h.tsv"
env CORALLINE_BURN_FILE="$ixp/burn-5h.tsv" CORALLINE_CONFIG="$tmp/conf" \
  "$EXE" <<<"{\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$((NOWT+7200))}}}" 2>/dev/null | mask > "$tmp/e"   # rust appends its own sample
env CORALLINE_BURN_FILE="$ixp/burn-5h.tsv" CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$tmp/conf" \
  bash "$US" <<<"{\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$((NOWT+7200))}}}" 2>/dev/null | mask > "$tmp/b"
if diff -q "$tmp/b" "$tmp/e" >/dev/null && grep -q "	55.000	" "$ix/burn-5h.tsv"; then
  printf '  ✓ %s\n' "interop: bash reads rust-appended burn samples"; pass=$((pass+1))
else printf '  ✗ %s\n' "interop: bash reads rust-appended burn samples"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
# trim rewrite equality: an over-cap file must be rewritten byte-identically,
# down to the canonical %d.%03d percentages the rewrite emits. Trimming is a
# mutation, so CORALLINE_NO_SAMPLE would suppress it; the payload carries no
# rate_limits instead, which keeps either renderer from appending a row of its
# own (whose timestamp would differ between the two runs).
mktrim() { for i in $(seq 1 1600); do printf '%s\t%s\t%s\n' $((NOWT-3200+i)) "4$((i%2)).${i}5" $((NOWT+7200)); done; }
mktrim > "$ix/tb.tsv"; mktrim > "$ix/te.tsv"
env CORALLINE_BURN_FILE="$ixp/tb.tsv" CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<'{}' >/dev/null 2>&1
env CORALLINE_BURN_FILE="$ixp/te.tsv" CORALLINE_CONFIG="$tmp/conf" "$EXE" <<<'{}' >/dev/null 2>&1
if diff -q "$ix/tb.tsv" "$ix/te.tsv" >/dev/null && [ "$(wc -l < "$ix/tb.tsv")" -le 1500 ]; then
  printf '  ✓ %s\n' "interop: burn trim rewrite is byte-identical"; pass=$((pass+1))
else printf '  ✗ %s\n' "interop: burn trim rewrite is byte-identical"; diff "$ix/tb.tsv" "$ix/te.tsv" | head -4; fail=$((fail+1)); fi
rm -rf "$ix"

# ── 2026-08 upstream features ────────────────────────────────────────────────
# Glyph overrides (#47): a terminal font without the plain-Unicode ⬡/⬢ can swap
# them for characters it does carry, on the main bar and the panel rows alike.
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="project ctx"\nVL_CTX_GLYPH="C"\nVL_PROJECT_GLYPH="P"\n' "$RT" > "$tmp/conf"
check "glyph: VL_CTX_GLYPH + VL_PROJECT_GLYPH"
printf '. %s/themes/claude-coral.conf\nVL_SUB_SEGMENTS="name ctx"\nVL_CTX_GLYPH="C"\n' "$RT" > "$tmp/conf"
CORALLINE_CONFIG="$tmp/conf" bash "$US" --subagent <<<"{\"tasks\":[{\"id\":\"g\",\"label\":\"glyph\",\"status\":\"running\",\"contextWindowSize\":200000,\"tokenCount\":42000}]}" 2>/dev/null > "$tmp/b"
CORALLINE_CONFIG="$tmp/conf" "$EXE" --subagent <<<"{\"tasks\":[{\"id\":\"g\",\"label\":\"glyph\",\"status\":\"running\",\"contextWindowSize\":200000,\"tokenCount\":42000}]}" 2>/dev/null > "$tmp/e"
if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "glyph: subagent ctx row"; pass=$((pass+1))
else printf '  ✗ %s\n' "glyph: subagent ctx row"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi

# VL_CTX_ALWAYS_SHOW / VL_COST_ALWAYS_SHOW: an empty-but-valid reading renders
# as 0% / $0.00; a malformed one still hides the segment.
alwayscheck() { # $1=label $2=payload
  COLUMNS= CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<"$2" 2>/dev/null | mask > "$tmp/b"
  COLUMNS= CORALLINE_CONFIG="$tmp/conf" "$EXE"      <<<"$2" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$1"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="ctx cost clock"\nVL_CTX_ALWAYS_SHOW=1\nVL_COST_ALWAYS_SHOW=1\n' "$RT" > "$tmp/conf"
alwayscheck "always-show: absent ctx/cost render as zero" '{"cwd":"/tmp"}'
alwayscheck "always-show: empty context_window object" '{"context_window":{},"cost":{}}'
alwayscheck "always-show: null used_percentage / total_cost_usd" '{"context_window":{"used_percentage":null},"cost":{"total_cost_usd":null}}'
alwayscheck "always-show: non-object context_window/cost stay hidden" '{"context_window":7,"cost":"x"}'
alwayscheck "always-show: real values still win" '{"context_window":{"used_percentage":62},"cost":{"total_cost_usd":1.23}}'
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="ctx cost clock"\n' "$RT" > "$tmp/conf"
alwayscheck "always-show: off by default" '{"cwd":"/tmp"}'
alwayscheck "cost: negative and out-of-range values are refused" '{"cost":{"total_cost_usd":-4}}'
alwayscheck "cost: exponent form" '{"cost":{"total_cost_usd":"1.5e-2"}}'

# The limit gauge after a window elapses (#57) and with no reading of our own
# (#63): an idle session keeps showing the window it last saw, and a session
# that has never had a reading borrows the store's still-open window.
le=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then lep=$(cygpath -m "$le"); else lep="$le"; fi
printf '. %s/themes/claude-coral.conf\nVL_LIMIT_SYNC=1\nVL_SEGMENTS="limit5h clock"\n' "$RT" > "$tmp/conf"
elapsedcheck() { # $1=label $2=payload
  env CORALLINE_RL5H_FILE="$lep/limit-5h.tsv" CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$tmp/conf" \
    bash "$US" <<<"$2" 2>/dev/null | mask > "$tmp/b"
  env CORALLINE_RL5H_FILE="$lep/limit-5h.tsv" CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$tmp/conf" \
    "$EXE" <<<"$2" 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else printf '  ✗ %s\n' "$1"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
}
elapsedcheck "limit sync: window elapsed minutes ago still renders" \
  "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":41,\"resets_at\":$((NOWT-600))}}}"
elapsedcheck "limit sync: window elapsed past the ceiling is dropped" \
  "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":41,\"resets_at\":$((NOWT-100000))}}}"
elapsedcheck "limit sync: no reset parsed → nothing to show" \
  '{"rate_limits":{"five_hour":{"used_percentage":41}}}'
mkdir -p "$le/limit-5h.d/$(printf '%010d_%07.3f' $((NOWT+3600)) 33.5)"
elapsedcheck "limit sync: store is the sole source without an own reading" '{}'
elapsedcheck "limit sync: a newer stored window beats an older own one" \
  "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":41,\"resets_at\":$((NOWT+60))}}}"
rm -rf "$le"

# HOME collapse: cwd under $HOME renders as ~/… with no stray characters.
# MSYS path-converts a POSIX-looking HOME before a native exe sees it (and
# normalizes slashes), so an identical HOME can't reach both renderers there —
# run this one on Linux/macOS only.
if ! command -v cygpath >/dev/null 2>&1; then
  printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="dir"\n' "$RT" > "$tmp/conf"
  env HOME=/Users/dev COLUMNS= CORALLINE_CONFIG="$tmp/conf" bash "$US" <<<'{"cwd":"/Users/dev/side-project"}' 2>/dev/null | mask > "$tmp/b"
  env HOME=/Users/dev COLUMNS= CORALLINE_CONFIG="$tmp/conf" "$EXE" <<<'{"cwd":"/Users/dev/side-project"}' 2>/dev/null | mask > "$tmp/e"
  if diff -q "$tmp/b" "$tmp/e" >/dev/null && grep -q '~/side-project' "$tmp/e"; then
    printf '  ✓ %s\n' "dir: clean ~ collapse under \$HOME"; pass=$((pass+1))
  else printf '  ✗ %s\n' "dir: clean ~ collapse under \$HOME"; diff "$tmp/b" "$tmp/e" | head -4; fail=$((fail+1)); fi
fi

rm -rf "$tmp" "$HOME/.claude/coralline/.cache/out-native" 2>/dev/null
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
