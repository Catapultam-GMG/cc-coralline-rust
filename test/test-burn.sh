#!/usr/bin/env bash
# Immutable burn / limit state regressions. Helpers are extracted live from the
# runtime so the parser, estimator, and trust-boundary tests cannot drift.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
case "$(uname -s)" in Darwin) TEST_TMP=/private/tmp ;; *) TEST_TMP=${TMPDIR:-/tmp} ;; esac
TMPD=$(mktemp -d "$TEST_TMP/coralline-burn.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM
fail=0
pass=0
ok() { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$2"; }
true_case() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "condition failed"; fi; }
count_entries() {
  _COUNT=0
  [ -d "$1" ] || return 0
  for _CE in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$_CE" ] || [ -L "$_CE" ] || continue
    _COUNT=$(( _COUNT + 1 ))
  done
}
first_name() {
  _FIRST=""
  for _FN in "$1"/*; do [ -e "$_FN" ] || continue; _FIRST=${_FN##*/}; break; done
}

# Pull the production implementations. The state block ends immediately before
# seg_burn; delete that opening line so eval sees complete function definitions.
eval "$(sed -n '/^to_epoch() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^fmt_eta() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^state_pct() {/,/^seg_burn() {/p' "$SCRIPT" | sed '$d')"
eval "$(sed -n '/^fg() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^push() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_burn() {/,/^}/p' "$SCRIPT")"

RL_MAX_5H=21600
RL_MAX_7D=691200
CORALLINE_BURN_WINDOW=600
BURN_TRIM=1500
VL_LIMIT_SYNC=0
CORALLINE_NO_SAMPLE=0

# Strict percent grammar and exact decimal ties-to-even canonicalization.
pct_case() {
  if state_pct "$2"; then eq "$1 milli" "$_SP_MILLI" "$3"; eq "$1 canonical" "$_SP_CANON" "$4"
  else bad "$1" "unexpected rejection"; fi
}
pct_reject() { if state_pct "$2"; then bad "$1" "accepted as $_SP_CANON"; else ok "$1"; fi; }
pct_case 'pct zero' '0' 0 '000.000'
pct_case 'pct integer' '41' 41000 '041.000'
pct_case 'pct six decimals' '41.200000' 41200 '041.200'
pct_case 'pct even midpoint stays' '1.2345' 1234 '001.234'
pct_case 'pct odd midpoint rises' '1.2355' 1236 '001.236'
pct_case 'pct below midpoint' '1.234499' 1234 '001.234'
pct_case 'pct above midpoint' '1.234501' 1235 '001.235'
pct_case 'pct carry to 100' '99.9995' 100000 '100.000'
pct_case 'pct exact 100' '100.000000' 100000 '100.000'
for _BAD_PCT in -0 00 01 +1 ' 1' '1 ' 100.000001 1,2 1e2 NaN Infinity 1.1234567 .5; do
  pct_reject "pct rejects $_BAD_PCT" "$_BAD_PCT"
done

# Strict epochs: no signs, decimals, leading zeroes, or overflow.
state_epoch 0 12; eq 'epoch zero' "$_SE_PAD" '000000000000'
state_epoch 253402300799 12; eq 'epoch max' "$_SE_VALUE" '253402300799'
state_epoch 9999999999 10; eq 'limit epoch max' "$_SE_PAD" '9999999999'
for _BAD_EP in -0 +1 01 1.0 253402300800 10000000000; do
  if state_epoch "$_BAD_EP" 10; then bad "epoch rejects $_BAD_EP" "accepted $_SE_PAD"; else ok "epoch rejects $_BAD_EP"; fi
done

# Exact rational midpoint-to-even and fixed ten-decimal rates.
state_round_even 5 2; eq 'round-even 2.5 to even' "$_RE" 2
state_round_even 7 2; eq 'round-even 3.5 to even' "$_RE" 4
state_round_even 4 3; eq 'round-even below half' "$_RE" 1
state_round_even 5 3; eq 'round-even above half' "$_RE" 2
state_rate10 10000000000 3; eq 'rate non-divisible' "$_RATE10" '0.3333333333'
state_rate10 19999999999 2; eq 'rate rounding carry' "$_RATE10" '1.0000000000'

# Store derivation and MSYS/native-drive path identity are lexical and fork-free.
PWD_SAVE=$PWD
cd "$TMPD"
state_store_path relative.tsv; eq 'relative store root' "$_SS_ROOT" "$TMPD/relative.d"
state_store_path C:/tmp/state.tsv; eq 'native drive store root' "$_SS_ROOT" '/c/tmp/state.d'
state_store_path 'C:\tmp\state.tsv'; eq 'backslash drive store root' "$_SS_ROOT" '/c/tmp/state.d'
state_store_path /c/tmp/state.tsv; eq 'MSYS drive store root' "$_SS_ROOT" '/c/tmp/state.d'
cd "$PWD_SAVE"

reset_state_case() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root"
  BURN_FILE="$root/burn.tsv"; RL5H_FILE="$root/limit5.tsv"; RL7D_FILE="$root/limit7.tsv"
  NOW=1000000; fh_pct=41.2; fh_rst=1015900; wd_pct=30; wd_rst=1345600
  CORALLINE_BURN_WINDOW=600; BURN_TRIM=1500; VL_LIMIT_SYNC=1; CORALLINE_NO_SAMPLE=0
  _STATE_BURN_GATE=1; _STATE_RL5_GATE=1; _STATE_RL7_GATE=1; _STATE_READY=0
}

# Store-root identity covers exact strings, existing filesystem objects, and the
# conservative Darwin/MSYS case rule without leaking nocasematch state.
true_case 'same-path exact string' state_same_path "$TMPD/missing-root" "$TMPD/missing-root"
mkdir -p "$TMPD/same-object"
true_case 'same-path existing filesystem object' state_same_path "$TMPD/same-object" "$TMPD/same-object/."
_NCM_WAS=0; shopt -q nocasematch && _NCM_WAS=1
shopt -u nocasematch
case "${OSTYPE:-}" in
  (darwin*|mingw*|msys*) true_case 'same-path conservatively folds platform case' state_same_path "$TMPD/Missing-Root" "$TMPD/missing-root" ;;
  (*) if state_same_path "$TMPD/Missing-Root" "$TMPD/missing-root"; then bad 'same-path keeps case-sensitive spellings distinct' 'reported same path'; else ok 'same-path keeps case-sensitive spellings distinct'; fi ;;
esac
if shopt -q nocasematch; then bad 'same-path restores disabled nocasematch' 'left enabled'; else ok 'same-path restores disabled nocasematch'; fi
shopt -s nocasematch
state_same_path "$TMPD/Missing-Root" "$TMPD/missing-root" >/dev/null 2>&1 || true
if shopt -q nocasematch; then ok 'same-path preserves enabled nocasematch'; else bad 'same-path preserves enabled nocasematch' 'left disabled'; fi
[ "$_NCM_WAS" = 1 ] || shopt -u nocasematch

# A case-only 5h/7d root alias must fail both stores closed before retention or
# publication. Run the physical alias regression only when the volume proves it.
CASE="$TMPD/case-root-collision"; reset_state_case "$CASE"; _STATE_BURN_GATE=0
RL5H_FILE="$CASE/State/limit.tsv"; RL7D_FILE="$CASE/state/limit.tsv"
mkdir -p "$CASE/State/limit.d/0001015900_040.000" "$CASE/State/limit.d/0001345600_029.000"
if [ -d "$CASE/state/limit.d" ] && [ "$CASE/State/limit.d" -ef "$CASE/state/limit.d" ]; then
  state_prepare
  eq 'case-only alias marks 5h incomplete' "$_SL5_COMPLETE" 0
  eq 'case-only alias marks 7d incomplete' "$_SL7_COMPLETE" 0
  true_case 'case-only alias preserves canonical 5h entry' test -d "$CASE/State/limit.d/0001015900_040.000"
  true_case 'case-only alias preserves canonical 7d entry' test -d "$CASE/State/limit.d/0001345600_029.000"
  count_entries "$CASE/State/limit.d"; eq 'case-only alias publishes nothing' "$_COUNT" 2
else
  ok 'case-only 5h/7d alias unavailable on case-sensitive volume'
fi

# A cold render publishes immutable zero-byte burn entries and limit directories.
CASE="$TMPD/publication"; reset_state_case "$CASE"; state_prepare
first_name "$CASE/burn.d"; eq 'burn strict live name' "$_FIRST" 'b_000001015900_000001000000_041.200_0000'
true_case 'burn entry zero-byte regular file' test ! -s "$CASE/burn.d/$_FIRST"
true_case 'limit5 canonical directory' test -d "$CASE/limit5.d/0001015900_041.200"
true_case 'limit7 canonical directory' test -d "$CASE/limit7.d/0001345600_030.000"
true_case 'new runtime never creates legacy burn TSV' test ! -e "$CASE/burn.tsv"
for _L in "$CASE/burn.d"/*; do case ${_L##*/} in l_*) bad 'no l_* entries' "found ${_L##*/}" ;; esac; done
ok 'no l_* entries'

# Same-second collisions consume deterministic slots and never overwrite.
state_prepare
true_case 'same-second slot 0001 committed' test -f "$CASE/burn.d/b_000001015900_000001000000_041.200_0001"
i=0
while [ "$i" -lt 32 ]; do printf -v _S '%04d' "$i"; : > "$CASE/burn.d/b_000001015900_000001000000_041.200_$_S"; i=$((i + 1)); done
count_entries "$CASE/burn.d"; _BEFORE=$_COUNT
_SB_RAW=0; _SB_REMOVED=0; _SB_COMPLETE=1; _SB_CLEAN=1; _SL5_COMPLETE=0; _SL7_COMPLETE=0; _STATE_MUTATE=1
state_publish; count_entries "$CASE/burn.d"; eq '32 occupied slots skip without growth' "$_COUNT" "$_BEFORE"

# Legacy TSV is a permanent bounded read-only source, never append/trim/heal.
CASE="$TMPD/legacy"; reset_state_case "$CASE"; fh_pct=8
printf '999640\t6\t1015900\n999700\t7\t1015900\n999940\t8\t1015900\n1000000\t8\t1015900\n9999999\t99\t99999999\n' > "$BURN_FILE"
cp "$BURN_FILE" "$CASE/legacy.before"
state_prepare
cmp -s "$BURN_FILE" "$CASE/legacy.before" && ok 'legacy bytes preserved under mutation' || bad 'legacy bytes preserved under mutation' 'content changed'
eq 'legacy estimator active' "$_B5_STATE" active
eq 'legacy estimator eta' "$_B5_ETA" 22080
true_case 'live samples publish only into .d' test -d "$CASE/burn.d"

# Exact estimator contract: same-second maximum, rational rate/ETA, and reset isolation.
NOW=1000360; CORALLINE_BURN_WINDOW=600; _SB_COMPLETE=1; _CUR_BURN_VALID=0
_SB_REP_RSTS=(1015900 1015900 1015900 1015900)
_SB_REP_SAMPS=(1000000 1000060 1000300 1000360)
_SB_REP_PCTS=(6000 7000 8000 8000)
_LEG_RSTS=(); _LEG_SAMPS=(); _LEG_PCTS=()
burn_eta_5h
eq '5h active state' "$_B5_STATE" active
eq '5h exact eta' "$_B5_ETA" 22080
eq '5h exact rate' "$_B5_RATE" '0.0041666667'
eq '5h ttr' "$_B5_TTR" 15540
_SB_REP_RSTS=(1015900 1015900 1015900 1015900 1015900)
_SB_REP_SAMPS=(1000000 1000060 1000060 1000300 1000360)
_SB_REP_PCTS=(6000 6500 7000 8000 8000)
burn_eta_5h; eq 'same-second maximum is order-independent' "$_B5_ETA" 22080
_SB_REP_RSTS=(1010000 1010000 1015900 1015900 1015900 1015900)
_SB_REP_SAMPS=(1000060 1000180 1000000 1000120 1000300 1000360)
_SB_REP_PCTS=(50000 51000 6000 7000 8000 8000)
burn_eta_5h; eq 'latest reset isolates old windows' "$_B5_ETA" 16560

NOW=1000000; burn_eta_7d 30000 1345600
eq '7d exact eta' "$_B7_ETA" 604800
eq '7d exact rate' "$_B7_RATE" '0.0001157407'
eq '7d ttr' "$_B7_TTR" 345600
burn_eta_7d 0 1345600; eq '7d zero pct is infinite' "$_B7_ETA" inf
_B5_STATE=active; _B5_ETA=5000; _B5_RATE=x; _B5_TTR=9000
_B7_ETA=5000; _B7_RATE=y; _B7_TTR=9000
burn_estimate; eq 'binding ETA tie chooses 5h' "$_BURN_LABEL" 5h

# Renderer consumes the precomputed result and never triggers state I/O itself.
VL_BURN_GLYPH='↗'; VL_BG_BURN=''; VL_BG_5H=237; VL_LAYOUT=fixed
VL_FG_OK=114; VL_FG_WARN=179; VL_FG_HOT=167; VL_FG_DIM=245; VL_NOCOLOR=0
fh_pct=8; wd_pct=0; _STATE_READY=0
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _BURN_STATE=active; _BURN_LABEL=5h; _BURN_ETA=1000; _BURN_RATE=0; _BURN_TTR=900
seg_burn
case "${SEG_TXT[0]}" in *'↗ 5h ⇢ 16m'*) ok 'burn renderer uses precomputed estimate' ;; *) bad 'burn renderer uses precomputed estimate' "${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;179m'*) ok 'burn warning color' ;; *) bad 'burn warning color' 'missing warning fg' ;; esac

# No-sample is strictly read-only for legacy, live stores, GC candidates, and
# missing roots. A poisoned strict sentinel remains physically present.
CASE="$TMPD/no-sample"; reset_state_case "$CASE"
mkdir -p "$CASE/burn.d" "$CASE/limit5.d/9999999999_099.000" "$CASE/limit7.d/9999999999_099.000"
: > "$CASE/burn.d/b_253402300799_000001000000_099.000_0000"
printf '1000000\t41.2\t1015900\n' > "$BURN_FILE"
cp "$BURN_FILE" "$CASE/legacy.before"
CORALLINE_NO_SAMPLE=1; state_prepare
cmp -s "$BURN_FILE" "$CASE/legacy.before" && ok 'no-sample preserves legacy bytes' || bad 'no-sample preserves legacy bytes' changed
true_case 'no-sample preserves burn sentinel' test -f "$CASE/burn.d/b_253402300799_000001000000_099.000_0000"
true_case 'no-sample preserves 5h sentinel' test -d "$CASE/limit5.d/9999999999_099.000"
true_case 'no-sample preserves 7d sentinel' test -d "$CASE/limit7.d/9999999999_099.000"
CASE2="$TMPD/no-sample-missing"; reset_state_case "$CASE2"; CORALLINE_NO_SAMPLE=1; state_prepare
true_case 'no-sample never creates missing burn root' test ! -e "$CASE2/burn.d"
true_case 'no-sample never creates missing limit root' test ! -e "$CASE2/limit5.d"

# Mutation-enabled complete snapshots may remove only exact strict sentinels;
# malformed entries and flat legacy limit files remain untouched.
CASE="$TMPD/gc-sentinel"; reset_state_case "$CASE"
mkdir -p "$CASE/burn.d" "$CASE/limit5.d/9999999999_099.000" "$CASE/limit5.d/not-state"
: > "$CASE/burn.d/b_253402300799_000001000000_099.000_0000"
: > "$CASE/burn.d/not-state"
printf 'flat-canary' > "$RL5H_FILE"
printf '1000000\t99\t99999999\n' > "$BURN_FILE"
state_prepare
true_case 'strict burn sentinel GCed' test ! -e "$CASE/burn.d/b_253402300799_000001000000_099.000_0000"
true_case 'malformed burn entry preserved' test -f "$CASE/burn.d/not-state"
true_case 'strict limit sentinel GCed' test ! -e "$CASE/limit5.d/9999999999_099.000"
true_case 'malformed limit entry preserved' test -d "$CASE/limit5.d/not-state"
eq 'flat limit file preserved' "$(LC_ALL=C tr -d '\n' < "$RL5H_FILE")" flat-canary
cmp -s "$BURN_FILE" <(printf '1000000\t99\t99999999\n') && ok 'legacy sentinel row preserved physically' || bad 'legacy sentinel row preserved physically' changed

# GC is snapshot-bound: an exact newer publication created after enumeration is
# absent from the candidate set and survives this round.
CASE="$TMPD/barrier"; reset_state_case "$CASE"; mkdir -p "$CASE/burn.d"
: > "$CASE/burn.d/b_253402300799_000001000000_099.000_0000"
_SB_NAMES=(); _SB_PATHS=(); _SB_RSTS=(); _SB_SAMPS=(); _SB_PCTS=(); _SB_PLAUS=(); _SB_RAW=0
_SL5_NAMES=(); _SL5_PATHS=(); _SL5_RSTS=(); _SL5_PCTS=(); _SL5_PLAUS=(); _SL5_RAW=0
_SL7_NAMES=(); _SL7_PATHS=(); _SL7_RSTS=(); _SL7_PCTS=(); _SL7_PLAUS=(); _SL7_RAW=0
_SB_ROOT="$CASE/burn.d"; _SB_BASE="$CASE/burn.tsv"; _STATE_FIND_ARGS=("$_SB_ROOT/.")
_STATE_LEGACY_READ=0; _STATE_BURN_GATE=1; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0
_SB_DIR_PREOK=1; _SL5_DIR_PREOK=0; _SL7_DIR_PREOK=0; _LEG_PREOK=1
_SB_DIR_COMPLETE=0; _SL5_COMPLETE=0; _SL7_COMPLETE=0; _LEG_COMPLETE=0
state_snapshot; _SB_COMPLETE=1; state_burn_retention
_NEW="$CASE/burn.d/b_000001015900_000001000001_042.000_0000"; : > "$_NEW"
_STATE_MUTATE=1; _SL5_CAND_PATHS=(); _SL5_CAND_TOTAL=0; _SL7_CAND_PATHS=(); _SL7_CAND_TOTAL=0
state_gc
true_case 'post-snapshot writer survives current GC' test -f "$_NEW"

# Bounded retention deletes at most 128 per render and blocks publication until
# every strict retention candidate from the complete snapshot is gone.
CASE="$TMPD/retention"; reset_state_case "$CASE"; BURN_TRIM=1; mkdir -p "$CASE/burn.d"
i=0
while [ "$i" -lt 130 ]; do
  sample=$(( NOW - 130 + i )); printf -v name 'b_%012d_%012d_%03d.%03d_%04d' 1015900 "$sample" 10 0 0
  : > "$CASE/burn.d/$name"; i=$((i + 1))
done
state_prepare; count_entries "$CASE/burn.d"; eq 'first retention round removes at most 128' "$_COUNT" 2
true_case 'publication blocked while candidate remains' test ! -e "$CASE/burn.d/b_000001015900_000001000000_041.200_0000"
state_prepare; count_entries "$CASE/burn.d"; eq 'second maintenance converges then publishes once' "$_COUNT" 2

# The default retained set is a normal steady state, not an adversarial input.
# Descending creation order exercises the O(n log n) in-shell merge sort.
CASE="$TMPD/steady1500"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; BURN_TRIM=1500
mkdir -p "$CASE/burn.d"; i=0
while [ "$i" -lt 1500 ]; do
  sample=$(( NOW - i - 1 )); printf -v name 'b_%012d_%012d_010.000_0000' 1015900 "$sample"
  : > "$CASE/burn.d/$name"; i=$(( i + 1 ))
done
_START=$SECONDS; state_prepare; _ELAPSED=$(( SECONDS - _START ))
[ "$_ELAPSED" -lt 5 ] && ok '1500-entry steady render completes under 5s' || bad '1500-entry steady render completes under 5s' "seconds=$_ELAPSED"
eq '1500-entry steady sort first sample' "${_SB_REP_SAMPS[0]}" 998500
eq '1500-entry steady sort last sample' "${_SB_REP_SAMPS[1499]}" 999999
count_entries "$CASE/burn.d"; eq '1500-entry steady render publishes once' "$_COUNT" 1501

# Raw snapshot and publication watermarks: malformed names consume capacity but
# are never deletion targets.
make_files() { local dir="$1" n="$2" i=0; mkdir -p "$dir"; while [ "$i" -lt "$n" ]; do printf -v _N 'x%04d' "$i"; : > "$dir/$_N"; i=$((i + 1)); done; }
CASE="$TMPD/watermark3967"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; make_files "$CASE/burn.d" 3967
state_prepare; count_entries "$CASE/burn.d"; eq 'burn raw 3967 may publish one' "$_COUNT" 3968
CASE="$TMPD/watermark3968"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; make_files "$CASE/burn.d" 3968
state_prepare; count_entries "$CASE/burn.d"; eq 'burn raw 3968 never publishes' "$_COUNT" 3968
CASE="$TMPD/overcap"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; make_files "$CASE/burn.d" 4097
state_prepare; count_entries "$CASE/burn.d"; eq 'burn cap+1 freezes store' "$_COUNT" 4097
eq 'burn cap+1 returns warming' "$_B5_STATE" warming

make_dirs() { local dir="$1" n="$2" i=0 paths=(); mkdir -p "$dir"; while [ "$i" -lt "$n" ]; do printf -v _N 'x%04d' "$i"; paths[${#paths[@]}]="$dir/$_N"; i=$((i + 1)); done; mkdir -p "${paths[@]}"; }
CASE="$TMPD/limit383"; reset_state_case "$CASE"; _STATE_BURN_GATE=0; _STATE_RL7_GATE=0; make_dirs "$CASE/limit5.d" 383
state_prepare; count_entries "$CASE/limit5.d"; eq 'limit raw 383 may publish one' "$_COUNT" 384
CASE="$TMPD/limit384"; reset_state_case "$CASE"; _STATE_BURN_GATE=0; _STATE_RL7_GATE=0; make_dirs "$CASE/limit5.d" 384
state_prepare; count_entries "$CASE/limit5.d"; eq 'limit raw 384 never publishes' "$_COUNT" 384
CASE="$TMPD/limit513"; reset_state_case "$CASE"; _STATE_BURN_GATE=0; _STATE_RL7_GATE=0; make_dirs "$CASE/limit5.d" 513
state_prepare; count_entries "$CASE/limit5.d"; eq 'limit cap+1 freezes store' "$_COUNT" 513

# Limit entries are immutable empty directories. The controller streams one
# bounded child layer so a poisoned canonical name cannot become stored state
# or force Bash to materialize an unbounded glob.
CASE="$TMPD/limit-nonempty"; reset_state_case "$CASE"; _STATE_BURN_GATE=0; _STATE_RL7_GATE=0
mkdir -p "$CASE/limit5.d/0001015900_041.200"; : > "$CASE/limit5.d/0001015900_041.200/canary"
state_prepare
eq 'nonempty limit directory is not stored state' "$_SL5_STORED_VALID" 0
eq 'nonempty limit directory blocks publication' "$_SL5_CLEAN" 0
true_case 'nonempty limit directory is preserved' test -f "$CASE/limit5.d/0001015900_041.200/canary"

CASE="$TMPD/limit-child-cap"; reset_state_case "$CASE"; _STATE_BURN_GATE=0; _STATE_RL7_GATE=0
mkdir -p "$CASE/limit5.d/0001015900_041.200"; i=0
while [ "$i" -lt 513 ]; do printf -v _N 'child%04d' "$i"; : > "$CASE/limit5.d/0001015900_041.200/$_N"; i=$((i + 1)); done
state_prepare
eq 'limit child cap+1 freezes store' "$_SL5_COMPLETE" 0
true_case 'limit child cap+1 preserves poisoned directory' test -f "$CASE/limit5.d/0001015900_041.200/child0512"

# Legacy byte/row/record caps and newest-512 valid-row ring.
CASE="$TMPD/legacy-bounds"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; CORALLINE_NO_SAMPLE=1
LC_ALL=C awk 'BEGIN { for (i=0;i<4096;i++) { for(j=0;j<255;j++) printf "x"; printf "\n" } }' > "$BURN_FILE"
state_prepare; eq 'exact 1MiB bounded legacy completes' "$_SB_COMPLETE" 1
printf x >> "$BURN_FILE"; state_prepare; eq 'legacy cap+1 is incomplete' "$_SB_COMPLETE" 0
: > "$BURN_FILE"; i=1
while [ "$i" -le 600 ]; do printf '%d\t1.2345\t1015900\n' "$i" >> "$BURN_FILE"; i=$((i + 1)); done
state_prepare; eq 'legacy ring retains 512 valid rows' "${#_LEG_RSTS[@]}" 512
eq 'legacy ring drops oldest valid rows' "${_LEG_SAMPS[0]}" 89
LC_ALL=C awk 'BEGIN { for(i=0;i<4097;i++) print "bad" }' > "$BURN_FILE"
state_prepare; eq 'legacy 4097 physical rows incomplete' "$_SB_COMPLETE" 0
LC_ALL=C awk 'BEGIN { for(i=0;i<4097;i++) printf "1"; printf "\n" }' > "$BURN_FILE"
state_prepare; eq 'legacy 4097-byte record incomplete' "$_SB_COMPLETE" 0
printf '1000000\t1\t1015900\0\n' > "$BURN_FILE"
state_prepare; eq 'legacy NUL row ignored after bounded read' "${#_LEG_RSTS[@]}" 0

# Controller failures discard partial data and forbid mutation.
CASE="$TMPD/controller-fail"; reset_state_case "$CASE"; mkdir -p "$CASE/burn.d"; : > "$CASE/burn.d/not-state"
REAL_FIND=$(command -v find); REAL_OD=$(command -v od); REAL_AWK=$(command -v awk)
mkdir -p "$CASE/bin"
printf '%s\n' '#!/bin/bash' 'printf "%s/./partial\0" "$WIN02_ROOT"' 'exit 7' > "$CASE/bin/find"; chmod +x "$CASE/bin/find"
printf '%s\n' '#!/bin/bash' 'exec "$WIN02_REAL_OD" "$@"' > "$CASE/bin/od"; chmod +x "$CASE/bin/od"
printf '%s\n' '#!/bin/bash' 'exec "$WIN02_REAL_AWK" "$@"' > "$CASE/bin/awk"; chmod +x "$CASE/bin/awk"
OLD_PATH=$PATH; export WIN02_ROOT="$CASE/burn.d" WIN02_REAL_OD="$REAL_OD" WIN02_REAL_AWK="$REAL_AWK"; PATH="$CASE/bin:$PATH"
state_prepare
PATH=$OLD_PATH
eq 'partial find failure marks burn incomplete' "$_SB_COMPLETE" 0
count_entries "$CASE/burn.d"; eq 'partial find failure performs no publication or GC' "$_COUNT" 1

CASE="$TMPD/legacy-fail"; reset_state_case "$CASE"; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0; printf '1000000\t1\t1015900\n' > "$BURN_FILE"
mkdir -p "$CASE/bin"
printf '%s\n' '#!/bin/bash' 'exec "$WIN02_REAL_FIND" "$@"' > "$CASE/bin/find"; chmod +x "$CASE/bin/find"
printf '%s\n' '#!/bin/bash' 'printf "49 48 48 48 48 48 48 9 49 9 49 48 49 53 57 48 48 10\n"' 'exit 7' > "$CASE/bin/od"; chmod +x "$CASE/bin/od"
printf '%s\n' '#!/bin/bash' 'exec "$WIN02_REAL_AWK" "$@"' > "$CASE/bin/awk"; chmod +x "$CASE/bin/awk"
export WIN02_REAL_FIND="$REAL_FIND" WIN02_REAL_AWK="$REAL_AWK"; PATH="$CASE/bin:$OLD_PATH"
state_prepare
PATH=$OLD_PATH
eq 'partial od failure marks legacy incomplete' "$_SB_COMPLETE" 0
eq 'partial od failure discards buffered rows' "${#_LEG_RSTS[@]}" 0
true_case 'partial od failure publishes nothing' test ! -e "$CASE/burn.d"

# Symlink stores and ancestors fail closed without touching their targets. Git
# Bash's default ln -s emulation copies directories, so create a real Windows
# reparse point there; native links are visible to Git Bash's -L predicate.
CASE="$TMPD/symlink"; reset_state_case "$CASE"; mkdir -p "$CASE/target"; : > "$CASE/target/canary"
case "$(uname -s)" in
  (MINGW*|MSYS*)
    _LINK_WIN=$(cygpath -w "$CASE/burn.d"); _TARGET_WIN=$(cygpath -w "$CASE/target")
    MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c mklink /J "$_LINK_WIN" "$_TARGET_WIN" >/dev/null 2>&1
    _LINK_OK=$? ;;
  (*) ln -s "$CASE/target" "$CASE/burn.d"; _LINK_OK=$? ;;
esac
true_case 'native symlink fixture created' test "$_LINK_OK" -eq 0
state_prepare
eq 'symlink store makes snapshot incomplete' "$_SB_COMPLETE" 0
true_case 'symlink target canary survives' test -f "$CASE/target/canary"
count_entries "$CASE/target"; eq 'symlink target receives no publication' "$_COUNT" 1

# Full-runtime gate and process budget. Wrappers exec the real tools in-place, so
# each trace line is one external state child; add one for the controller.
if command -v jq >/dev/null 2>&1; then
  make_payload() {
    local path="$1" now reset
    now=$(date +%s); reset=$((now + 10800))
    jq --arg r "$reset" '.rate_limits.five_hour.resets_at=$r | .rate_limits.seven_day.resets_at=$r' "$HERE/sample-input.json" > "$path"
  }
  trace_wrappers() {
    local dir="$1" tool real
    mkdir -p "$dir"
    for tool in find od awk rm mkdir; do
      real=$(command -v "$tool")
      {
        printf '%s\n' '#!/bin/bash'
        printf 'printf "%%s\\n" %q >> "$WIN02_TRACE"\n' "$tool"
        printf 'exec %q "$@"\n' "$real"
      } > "$dir/$tool"
      chmod +x "$dir/$tool"
    done
  }
  CASE="$TMPD/process"; mkdir -p "$CASE"; make_payload "$CASE/input"; trace_wrappers "$CASE/bin"
  printf '%s\n' 'VL_SEGMENTS=dir' 'VL_CLOCK=off' > "$CASE/disabled.conf"
  : > "$CASE/disabled.log"
  WIN02_TRACE="$CASE/disabled.log" CORALLINE_CONFIG="$CASE/disabled.conf" PATH="$CASE/bin:$PATH" bash "$SCRIPT" < "$CASE/input" >/dev/null 2> "$CASE/disabled.err"
  _TRACE=0; while IFS= read -r _; do _TRACE=$((_TRACE + 1)); done < "$CASE/disabled.log"
  eq 'disabled state adds zero children' "$_TRACE" 0
  eq 'disabled state stderr empty' "$(wc -c < "$CASE/disabled.err" | tr -d ' ')" 0

  mkdir -p "$CASE/state/burn.d"; printf '1\t1\t2\n' > "$CASE/state/burn.tsv"
  printf '%s\n' 'VL_SEGMENTS=burn' 'VL_CLOCK=off' "BURN_FILE=$CASE/state/burn.tsv" > "$CASE/read.conf"
  : > "$CASE/read.log"
  WIN02_TRACE="$CASE/read.log" CORALLINE_CONFIG="$CASE/read.conf" CORALLINE_NO_SAMPLE=1 PATH="$CASE/bin:$PATH" bash "$SCRIPT" < "$CASE/input" >/dev/null 2> "$CASE/read.err"
  _TRACE=1; while IFS= read -r _; do _TRACE=$((_TRACE + 1)); done < "$CASE/read.log"
  [ "$_TRACE" -le 4 ] && ok 'no-sample descendant ceiling <=4' || bad 'no-sample descendant ceiling <=4' "count=$_TRACE"
  eq 'no-sample process trace stderr empty' "$(wc -c < "$CASE/read.err" | tr -d ' ')" 0

  rm -rf "$CASE/state"; mkdir -p "$CASE/state/burn.d"
  now=$(date +%s); old=$((now - 10)); reset=$((now + 10800)); printf -v oldname 'b_%012d_%012d_010.000_0000' "$reset" "$old"; : > "$CASE/state/burn.d/$oldname"
  old=$((now - 9)); printf -v oldname 'b_%012d_%012d_011.000_0000' "$reset" "$old"; : > "$CASE/state/burn.d/$oldname"
  printf '1\t1\t2\n' > "$CASE/state/burn.tsv"
  printf '%s\n' 'VL_SEGMENTS=burn\ limit5h\ limit7d' 'VL_LIMIT_SYNC=1' 'VL_CLOCK=off' "BURN_FILE=$CASE/state/burn.tsv" "RL5H_FILE=$CASE/state/limit5.tsv" "RL7D_FILE=$CASE/state/limit7.tsv" 'BURN_TRIM=1' > "$CASE/full.conf"
  : > "$CASE/full.log"
  WIN02_TRACE="$CASE/full.log" CORALLINE_CONFIG="$CASE/full.conf" PATH="$CASE/bin:$PATH" bash "$SCRIPT" < "$CASE/input" >/dev/null 2> "$CASE/full.err"
  _TRACE=1; while IFS= read -r _; do _TRACE=$((_TRACE + 1)); done < "$CASE/full.log"
  [ "$_TRACE" -le 6 ] && ok 'fully enabled descendant ceiling <=6' || bad 'fully enabled descendant ceiling <=6' "count=$_TRACE"
  eq 'fully enabled process trace stderr empty' "$(wc -c < "$CASE/full.err" | tr -d ' ')" 0

  printf '%s\n' 'VL_SEGMENTS=dir' 'VL_CLOCK=off' "BURN_FILE=$CASE/gated/burn.tsv" > "$CASE/gate.conf"
  CORALLINE_CONFIG="$CASE/gate.conf" bash "$SCRIPT" < "$CASE/input" >/dev/null 2>/dev/null
  true_case 'burn absent never creates state root' test ! -e "$CASE/gated/burn.d"
else
  ok 'full-runtime gate and process budget skipped without jq'
fi

printf 'SUMMARY pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ALL PASS\n'
