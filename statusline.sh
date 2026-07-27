#!/usr/bin/env bash
# coralline — a configurable, Powerlevel10k-inspired statusline for Claude Code
# https://github.com/Nanako0129/coralline
# Visual style is a tribute to https://github.com/romkatv/powerlevel10k
#
# Design goals:
#   * Minimal process spawning per render — helpers return via globals
#     (printf -v) instead of $(...) subshells, so it stays cheap even under
#     Git Bash on Windows, where fork() is emulated and expensive.
#   * One jq call, one git call. Pure bash arithmetic (no bc).
#   * Works on macOS bash 3.2 and Linux/Windows (Git Bash) bash 4+/5.
#   * Everything themeable via ~/.claude/coralline.conf (sourced bash)
#
# Requires: jq, and a Nerd Font terminal unless VL_ASCII=1

# --subagent: speak Claude Code's subagentStatusLine protocol instead — one
# {"id","content"} JSON line per agent-panel row (see the branch after the
# render helpers). Everything else (config, theme, helpers) is shared.
SUBAGENT_MODE=0
[ "${1:-}" = "--subagent" ] && SUBAGENT_MODE=1

# -d '' reads until NUL (i.e. all of stdin, like cat) without forking.
# -t 5 prevents zombie bash on MSYS2 where pipe EOF may never arrive.
read -t 5 -r -d '' input || true

# ── Defaults (every value can be overridden by the config file) ──────────────
VL_STYLE="pill"                 # pill: powerline pills · lean: flat text · classic: lean on a dark bar
VL_LEAN_SEP=""                  # lean only — extra text between segments, e.g. "·"
VL_LEAN_BG=""                   # lean only — one uniform background behind the whole
                                # row ("R,G,B" or a 256 index); empty = none. Gives the
                                # p10k "classic" look: a dark bar with colored text.
VL_LEAN_CAP_R=""                # lean only — trailing cap glyph drawn in the VL_LEAN_BG
                                # colour to bevel the bar into the terminal (p10k's end
                                # separator, e.g. $''); needs VL_LEAN_BG, empty = flat
VL_LEAN_CAP_L=""                # lean only — leading cap glyph: the left-facing
                                # mirror of VL_LEAN_CAP_R at the bar's start; needs
                                # VL_LEAN_BG, empty = flat (stock p10k classic: flat)
VL_LAYOUT="fixed"               # fixed: one line per VL_SEGMENTS* var
                                # auto:  single line, wraps when the window is narrow
VL_MAX_LINES=3                  # auto only — wrap into at most this many lines
VL_WRAP_MARGIN=4                # auto only — keep this many columns free on the right.
                                # 4 covers Claude Code's full-width L/R padding (2 cols each)
VL_SEGMENTS="dir git model ctx limit5h limit7d cost clock"
VL_SEGMENTS2=""                 # fixed only — optional second line
VL_SEGMENTS3=""                 # fixed only — optional third line
VL_BAR_WIDTH=5
VL_BAR_FILL="▰"
VL_BAR_EMPTY="▱"
# Segment glyphs. These four are plain Unicode, not Nerd Font PUA icons, so a
# font that lacks them leaves the substitution to the terminal's own fallback —
# which may land on a glyph wider than one cell and shove the rest of the row
# out of alignment (#47). Override with characters your terminal font carries.
VL_CTX_GLYPH="⬡"                # glyph for the ctx segment (main bar and subagent rows)
VL_PROJECT_GLYPH="⬢"            # glyph for the project segment
VL_CLOCK="12h"                  # 12h | 24h | off
VL_CLOCK_SECONDS=1
VL_PATH_DEPTH=4                 # collapse paths deeper than this
VL_NAME_MAX=0                   # max chars for project/git names before … truncation (0 = off)
VL_COST_DECIMALS=2
VL_WARN_PCT=50                  # percentage thresholds for bar colors
VL_HOT_PCT=75
VL_ASCII=0                      # 1 = no Nerd Font glyphs (plain colored blocks)
VL_FLOAT=0                      # 1 = also write a plain-text readout to VL_FLOAT_FILE (bring your own carrier)
VL_FLOAT_SEGMENTS="model ctx cost"  # segments rendered into the float line (plain text: keep color-driven limit warnings inline)
VL_FLOAT_SEP="  ·  "            # separator between float segments (plain text, no color)
VL_FLOAT_FILE="$HOME/.claude/coralline/float.txt"
VL_NOCOLOR=0                    # internal: fg()/bg() emit nothing when 1 (plain-text path)

# ── Subagent panel rows (--subagent mode) ────────────────────────────────────
VL_SUB_SEGMENTS="name model ctx elapsed"  # panel-row segment list (subseg_*)
VL_BG_SUB_NAME=""               # panel-row colors; empty → fall back to the
VL_BG_SUB_MODEL=""              #   main-bar counterparts (dir/model/ctx/duration)
VL_BG_SUB_CTX=""
VL_BG_SUB_ELAPSED=""

# ── Burn-rate segment (range-to-empty) ───────────────────────────────────────
# Opt in by adding `burn` to VL_SEGMENTS*; the sampler below runs only then.
CORALLINE_BURN_WINDOW=600       # recent-slope lookback for 5h, seconds
VL_BURN_GLYPH="↗"               # plain-Unicode, arrow family (kept in VL_ASCII)
VL_BG_BURN=""                   # empty → inherits VL_BG_5H at the use site
BURN_FILE="${CORALLINE_BURN_FILE:-$HOME/.claude/coralline/burn-5h.tsv}"
BURN_TRIM=1500                  # internal: max rows kept in the sample file

# Cross-session limit sync (opt-in). Claude Code only re-renders a session's
# statusline on activity, and the rate-limit % in each render's JSON is that
# session's last-seen snapshot, so idle sessions show stale/divergent numbers.
# With this on, every render records its 5h/7d (reset, pct) to a small per-host
# high-water store, and limit5h/limit7d show the highest pct any session has seen
# for the current window — so sessions converge whenever they redraw. It cannot
# refresh a session that is not redrawing at all (that is a Claude Code limit).
# The store is a directory-set (see rl_sample/rl_latest), race-free by design.
VL_LIMIT_SYNC=0
RL5H_FILE="${CORALLINE_RL5H_FILE:-$HOME/.claude/coralline/limit-5h.tsv}"
RL7D_FILE="${CORALLINE_RL7D_FILE:-$HOME/.claude/coralline/limit-7d.tsv}"
# Per-window ceilings for the sentinel guard (#32): a reset further out than its
# window can possibly be is corrupt (e.g. sample-input.json's 2030 value) and must
# never become the high-water. Kept per window because a stale 5h value a couple of
# days out would clear a shared 7d-sized bound, so the 5h path needs its own.
RL_MAX_5H=$(( 6 * 3600 ))       # internal: 5h window resets within ~5h (6h = +1h skew margin)
RL_MAX_7D=$(( 8 * 86400 ))      # internal: 7d window resets within 7d (8d = +1d skew margin)

# Powerline glyphs (printf -v keeps these fork-free; cleared when VL_ASCII=1)
printf -v VL_CAP_L '\xee\x82\xb6'   # U+E0B6 left rounded cap
printf -v VL_CAP_R '\xee\x82\xb4'   # U+E0B4 right rounded cap
printf -v VL_SEP   '\xee\x82\xb0'   # U+E0B0 segment separator

# Default theme: claude-coral (steel blue · mauve · Claude coral)
VL_BG_DIR="81,166,199"
VL_BG_PROJECT=""               # optional; falls back to VL_BG_DIR when empty
VL_BG_GIT_OK=65
VL_BG_STASH=""                 # optional; falls back to VL_BG_GIT_OK when empty
VL_BG_GIT_DIRTY=130
VL_BG_MODEL=173
VL_BG_CTX=238
VL_BG_5H=237
VL_BG_7D=236
VL_BG_COST="212,125,145"
VL_BG_CLOCK="70,80,110"
VL_BG_LINES=240
VL_BG_STYLE=96
VL_BG_DURATION=60
VL_BG_EFFORT=141
VL_BG_NODE=""                   # optional; falls back to VL_BG_MODEL when empty
VL_BG_PYTHON=""                 # optional; falls back to VL_BG_MODEL when empty
VL_BG_BAR=""                   # classic style only — the uniform bar behind the whole
                               # row ("R,G,B" or a 256 index); empty → p10k's 238.
                               # An explicit VL_LEAN_BG overrides it.
printf -v VL_NODE_GLYPH '\xee\x9c\x98'   # U+E718 Nerd Font node glyph (word in VL_ASCII)
printf -v VL_PY_GLYPH   '\xee\x9c\xbc'   # U+E73C Nerd Font python glyph (word in VL_ASCII)
VL_RUNTIME_PROBE=0              # node/python: 1 = also detect via `node`/`python3`
                               # on PATH when no pin file (forks per render; off by default)

VL_FG_TEXT=231
VL_FG_DIM=245
VL_FG_OK=114
VL_FG_WARN=179
VL_FG_HOT=167

# ── Load user config ─────────────────────────────────────────────────────────
VL_CONF="${CORALLINE_CONFIG:-$HOME/.claude/coralline.conf}"
[ -f "$VL_CONF" ] && . "$VL_CONF"

if [ "$VL_ASCII" = "1" ]; then
  VL_CAP_L="" ; VL_CAP_R="" ; VL_SEP=""
  VL_BAR_FILL="#" ; VL_BAR_EMPTY="-"
  VL_NODE_GLYPH="node" ; VL_PY_GLYPH="py"
fi

# Classic style: Powerlevel10k's stock "Classic" preset — lean rendering on one
# uniform dark bar (VL_BG_BAR, default p10k 238) with a solid trailing cap (VL_SEP,
# p10k's U+E0B0). It is lean plus those two structural defaults, so resolve it here.
# Placement matters: after the VL_ASCII block (so in ASCII mode VL_SEP is already
# cleared → the cap stays empty but the bar still paints) and before the lean block
# (so lean rendering then fires). The := chain lets an explicit VL_LEAN_BG /
# VL_LEAN_CAP_R win. Pure parameter expansion, run once — the render path stays
# fork-free.
if [ "$VL_STYLE" = "classic" ]; then
  VL_STYLE="lean"
  : "${VL_LEAN_BG:=${VL_BG_BAR:-238}}"
  : "${VL_LEAN_CAP_R:=$VL_SEP}"
fi

# Lean style: no caps and no per-segment pills; each segment's VL_BG_* becomes its
# text accent color (an empty VL_FG_TEXT lets text inherit that accent). VL_LEAN_BG
# can still paint one uniform background behind the row (the p10k "classic" look).
if [ "$VL_STYLE" = "lean" ]; then
  VL_CAP_L="" ; VL_CAP_R=""
  VL_FG_TEXT="${VL_LEAN_FG:-}"
fi

# Current epoch, computed once. printf %(...)T is a fork-free builtin on
# bash 4.2+ (incl. Git Bash); fall back to a single date call on macOS 3.2.
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)

# ── ANSI primitives ──────────────────────────────────────────────────────────
R=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'

# fg/bg set $_FG / $_BG to an ANSI escape (no subshell). Accept a 256-color
# index, a "R,G,B" true-color triple, or empty (→ empty string, inherit color).
fg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _FG=""; return; fi
  if [ -z "$1" ]; then _FG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _FG '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _FG '\033[38;5;%sm' "$1"; fi
}
bg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _BG=""; return; fi
  if [ -z "$1" ]; then _BG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _BG '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _BG '\033[48;5;%sm' "$1"; fi
}

# ── Helpers (all return via a global, never via $() ) ─────────────────────────
make_bar() {  # → _BAR ; $1=pct $2=width
  local pct="${1:-0}" width="${2:-$VL_BAR_WIDTH}" i filled
  _BAR=""
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt "$width" ] && filled=$width
  for ((i=0; i<filled; i++));     do _BAR="${_BAR}${VL_BAR_FILL}";  done
  for ((i=filled; i<width; i++)); do _BAR="${_BAR}${VL_BAR_EMPTY}"; done
}

# 1234 → 1.2k · 1234567 → 1.2M (integer math only) → _TOK
fmt_tok() {
  local n="${1:-0}"
  case "$n" in (''|*[!0-9]*) _TOK="$n"; return ;; esac
  if   [ "$n" -ge 1000000 ]; then printf -v _TOK '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [ "$n" -ge 1000 ];    then printf -v _TOK '%d.%dk' $((n/1000))    $(((n%1000)/100))
  else _TOK="$n"; fi
}

# Canonical UTC ISO timestamp → _EP, using pure integer date math. Returns 1 for
# every non-canonical or calendar-invalid value; callers decide whether to fall
# back to the platform date command.
iso_epoch() {
  local t="$1" s tm Y Mo D H Mi S yy era yoe doy doe days dim
  case "$t" in (*T*) ;; (*) return 1 ;; esac
  tm="${t#*T}"
  case "$tm" in (*[+-]*) return 1 ;; esac
  s="${t%Z}" ; s="${s%%.*}"              # drop trailing Z and any fraction
  case "$s" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  # Fixed offsets are safe now that the exact shape is confirmed. 10# forces
  # base-10 so a leading zero (08, 09) is not read as octal.
  Y=$((10#${s:0:4})); Mo=$((10#${s:5:2})); D=$((10#${s:8:2}))
  H=$((10#${s:11:2})); Mi=$((10#${s:14:2})); S=$((10#${s:17:2}))
  dim=31                                    # days in month, for range validation
  case $Mo in
    4|6|9|11) dim=30 ;;
    2) dim=$(( (Y % 4 == 0 && (Y % 100 != 0 || Y % 400 == 0)) ? 29 : 28 )) ;;
  esac
  [ "$Mo" -ge 1 ] && [ "$Mo" -le 12 ] && [ "$D" -ge 1 ] && [ "$D" -le "$dim" ] \
    && [ "$H" -le 23 ] && [ "$Mi" -le 59 ] && [ "$S" -le 59 ] || return 1
  yy=$(( Y - (Mo <= 2) ))                   # days-from-civil (Howard Hinnant), UTC
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (Mo + (Mo > 2 ? -3 : 9)) + 2) / 5 + D - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  _EP=$(( days * 86400 + H * 3600 + Mi * 60 + S ))
}

# Accepts epoch seconds (with or without decimals) or an ISO 8601 timestamp → _EP.
# Claude Code sends rate-limit resets_at as ISO UTC ("…Z"). The common shape is
# parsed fork-free by iso_epoch; non-standard or impossible values retain the old
# platform-date fallback so main-statusline behavior stays byte-compatible.
to_epoch() {
  local t="$1" s
  [ -z "$t" ] && return 1
  case "$t" in
    *T*)
      iso_epoch "$t" && return 0
      _EP=$(date -u -d "$t" +%s 2>/dev/null) && return 0
      s="${t%%[.+]*}" ; s="${s%Z}"
      _EP=$(date -ju -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null) && return 0
      return 1 ;;
    *[0-9]*) _EP="${t%%.*}" ; return 0 ;;
    *) return 1 ;;
  esac
}

fmt_countdown() {  # → _CD ("" if no/expired input handled by caller); $1=resets_at
  local diff d h m
  _CD=""
  to_epoch "$1" || return 0
  diff=$(( _EP - NOW ))
  if [ "$diff" -le 0 ]; then _CD="now"; return; fi
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf -v _CD '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v _CD '%dh%02dm' "$h" "$m"
  else                      printf -v _CD '%dm' "$m"; fi
}

fmt_duration() {  # → _DUR ; $1=ms $2=include seconds
  local ms="${1:-0}" s h m sec
  s=$(( ms / 1000 )); h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); sec=$(( s % 60 ))
  if [ "${2:-0}" = "1" ]; then
    if   [ "$h" -gt 0 ]; then printf -v _DUR '%dh%02dm%02ds' "$h" "$m" "$sec"
    elif [ "$m" -gt 0 ]; then printf -v _DUR '%dm%02ds' "$m" "$sec"
    else                      printf -v _DUR '%ds' "$s"; fi
  elif [ "$h" -gt 0 ]; then printf -v _DUR '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf -v _DUR '%dm' "$m"
  else                      printf -v _DUR '%ds' "$s"; fi
}

fmt_eta() {  # → _ETA ; $1=seconds (mirrors fmt_countdown's d/h/m formatting)
  local s="${1:-0}" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf -v _ETA '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v _ETA '%dh%02dm' "$h" "$m"
  else                      printf -v _ETA '%dm' "$m"; fi
}

# ── Immutable burn / limit state ──────────────────────────────────────────────
# State percentages are canonical integer milli-percent. Filenames, not file
# contents or enumeration order, are the shared source of truth.
state_pct() {  # → _SP_MILLI _SP_CANON; strict raw decimal, ties-to-even at .001
  local raw="$1" whole frac six keep rest milli LC_ALL=C
  _SP_MILLI=""; _SP_CANON=""
  [[ "$raw" =~ ^(0|[1-9][0-9]?|100)(\.([0-9]{1,6}))?$ ]] || return 1
  whole="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]}"
  if [ "$whole" = 100 ]; then
    case "$frac" in (*[!0]*) return 1 ;; esac
  fi
  six="${frac}000000"; six="${six:0:6}"
  keep=${six:0:3}; rest=${six:3:3}
  milli=$(( 10#$whole * 1000 + 10#$keep ))
  if [ $(( 10#$rest )) -gt 500 ] || { [ $(( 10#$rest )) -eq 500 ] && [ $(( milli % 2 )) -eq 1 ]; }; then
    milli=$(( milli + 1 ))
  fi
  [ "$milli" -le 100000 ] || return 1
  _SP_MILLI=$milli
  printf -v _SP_CANON '%03d.%03d' $(( milli / 1000 )) $(( milli % 1000 ))
}

state_epoch() {  # → _SE_VALUE _SE_PAD; $1=strict epoch $2=width (10 or 12)
  local raw="$1" width="$2" value
  _SE_VALUE=""; _SE_PAD=""
  case "$raw" in (0|[1-9][0-9]*) ;; (*) return 1 ;; esac
  case "$raw" in (*[!0-9]*) return 1 ;; esac
  [ "${#raw}" -le 12 ] || return 1
  value=$(( 10#$raw ))
  [ "$value" -ge 0 ] && [ "$value" -le 253402300799 ] || return 1
  [ "$width" != 10 ] || [ "$value" -le 9999999999 ] || return 1
  _SE_VALUE=$value
  printf -v _SE_PAD "%0${width}d" "$value"
}

state_payload_epoch() {  # → _SE_*; canonical ISO UTC or strict epoch only
  local raw="$1" width="$2"
  case "$raw" in
    (*T*) to_epoch "$raw" || return 1; state_epoch "$_EP" "$width" ;;
    (*) state_epoch "$raw" "$width" ;;
  esac
}

state_round_even() {  # → _RE; exact nonnegative rational midpoint-to-even
  local n="$1" d="$2" q r twice
  _RE=0
  [ "$d" -gt 0 ] || return 1
  q=$(( n / d )); r=$(( n % d )); twice=$(( r * 2 ))
  if [ "$twice" -gt "$d" ] || { [ "$twice" -eq "$d" ] && [ $(( q % 2 )) -eq 1 ]; }; then
    q=$(( q + 1 ))
  fi
  _RE=$q
}

state_rate10() {  # → _RATE10; $1=scaled numerator $2=denominator
  local scaled
  state_round_even "$1" "$2" || { _RATE10="0.0000000000"; return 1; }
  scaled=$_RE
  printf -v _RATE10 '%d.%010d' $(( scaled / 10000000000 )) $(( scaled % 10000000000 ))
}

state_drive_lower() {  # → _SDL
  case "$1" in
    (A|a) _SDL=a ;; (B|b) _SDL=b ;; (C|c) _SDL=c ;; (D|d) _SDL=d ;;
    (E|e) _SDL=e ;; (F|f) _SDL=f ;; (G|g) _SDL=g ;; (H|h) _SDL=h ;;
    (I|i) _SDL=i ;; (J|j) _SDL=j ;; (K|k) _SDL=k ;; (L|l) _SDL=l ;;
    (M|m) _SDL=m ;; (N|n) _SDL=n ;; (O|o) _SDL=o ;; (P|p) _SDL=p ;;
    (Q|q) _SDL=q ;; (R|r) _SDL=r ;; (S|s) _SDL=s ;; (T|t) _SDL=t ;;
    (U|u) _SDL=u ;; (V|v) _SDL=v ;; (W|w) _SDL=w ;; (X|x) _SDL=x ;;
    (Y|y) _SDL=y ;; (Z|z) _SDL=z ;; (*) return 1 ;;
  esac
}

state_abs_path() {  # → _SAP; lexical absolute path, including MSYS drive forms
  local p="$1" drive rest part out=""
  _SAP=""
  [ -n "$p" ] || return 1
  p="${p//\\//}"
  case "$p" in
    (//*) return 1 ;;
    ([abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]:/*)
      drive=${p:0:1}; state_drive_lower "$drive" || return 1
      p="/${_SDL}/${p:3}" ;;
    (/*) ;;
    (*) p="$PWD/$p" ;;
  esac
  rest="${p#/}"
  while :; do
    part="${rest%%/*}"
    case "$part" in
      (''|.) ;;
      (..) [ -n "$out" ] || return 1; out="${out%/*}" ;;
      (*) out="${out:+$out/}$part" ;;
    esac
    [ "$rest" = "$part" ] && break
    rest="${rest#*/}"
  done
  _SAP="/${out}"
  [ "$_SAP" != "/" ] || _SAP="/"
}

state_no_symlink_path() {  # → _SNP; every existing ancestor and target is non-link
  local path="$1" rest part cur="" tail
  _SNP=""
  state_abs_path "$path" || return 1
  path="$_SAP"; rest="${path#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"; tail="${rest#*/}"
    cur="$cur/$part"
    [ -L "$cur" ] && return 1
    if [ "$tail" != "$rest" ] && [ -e "$cur" ] && [ ! -d "$cur" ]; then return 1; fi
    [ "$tail" = "$rest" ] && break
    rest="$tail"
  done
  _SNP="$path"
}

state_store_path() {  # → _SS_BASE _SS_ROOT from configured base
  state_abs_path "$1" || return 1
  _SS_BASE="$_SAP"
  _SS_ROOT="${_SS_BASE%.tsv}.d"
  [ "$_SS_ROOT" != "$_SS_BASE" ] || _SS_ROOT="${_SS_BASE}.d"
}

state_same_path() {  # true for proven or platform-conservative store-root identity
  local left="$1" right="$2" had_nocase=0 same=1
  [ "$left" = "$right" ] && return 0
  if [ -e "$left" ] && [ -e "$right" ] && [ "$left" -ef "$right" ]; then return 0; fi
  case "${OSTYPE:-}" in
    (darwin*|mingw*|msys*)
      shopt -q nocasematch && had_nocase=1
      shopt -s nocasematch
      [[ "$left" == "$right" ]] && same=0
      [ "$had_nocase" = 1 ] || shopt -u nocasematch
      return "$same"
      ;;
  esac
  return 1
}

state_burn_name() {  # → _SBN_* for one strict live basename
  local name="$1" pr ps pc LC_ALL=C
  _SBN_RST=""; _SBN_SAMP=""; _SBN_PCT=""; _SBN_SLOT=""
  [[ "$name" =~ ^b_([0-9]{12})_([0-9]{12})_((0[0-9]{2}|100)\.[0-9]{3})_([0-9]{4})$ ]] || return 1
  pr="${BASH_REMATCH[1]}"; ps="${BASH_REMATCH[2]}"; pc="${BASH_REMATCH[3]}"
  _SBN_RST=$(( 10#$pr )); _SBN_SAMP=$(( 10#$ps ))
  [ "$_SBN_RST" -le 253402300799 ] && [ "$_SBN_SAMP" -le 253402300799 ] || return 1
  _SBN_PCT=$(( 10#${pc:0:3} * 1000 + 10#${pc:4:3} ))
  [ "$_SBN_PCT" -le 100000 ] || return 1
  _SBN_SLOT="${BASH_REMATCH[5]}"
}

state_limit_name() {  # → _SLN_RST _SLN_PCT for one strict limit basename
  local name="$1" pr pc LC_ALL=C
  _SLN_RST=""; _SLN_PCT=""
  [[ "$name" =~ ^([0-9]{10})_((0[0-9]{2}|100)\.[0-9]{3})$ ]] || return 1
  pr="${BASH_REMATCH[1]}"; pc="${BASH_REMATCH[2]}"
  _SLN_RST=$(( 10#$pr ))
  _SLN_PCT=$(( 10#${pc:0:3} * 1000 + 10#${pc:4:3} ))
  [ "$_SLN_PCT" -le 100000 ] || return 1
}

state_add_burn_path() {
  local path="$1" name="$2" i plausible=0
  _SB_RAW=$(( _SB_RAW + 1 ))
  state_burn_name "$name" || return 0
  [ -f "$path" ] && [ ! -L "$path" ] && [ ! -s "$path" ] || return 0
  if [ "$_SBN_SAMP" -le $(( NOW + 300 )) ] && [ "$_SBN_RST" -ge "$_SBN_SAMP" ] \
     && [ "$_SBN_RST" -le $(( NOW + RL_MAX_5H )) ]; then plausible=1; fi
  i=${#_SB_NAMES[@]}
  _SB_NAMES[$i]="$name"; _SB_PATHS[$i]="$path"; _SB_RSTS[$i]="$_SBN_RST"
  _SB_SAMPS[$i]="$_SBN_SAMP"; _SB_PCTS[$i]="$_SBN_PCT"; _SB_PLAUS[$i]="$plausible"
}

state_add_limit_path() {  # $1=5|7 $2=path $3=name
  local which="$1" path="$2" name="$3" i plausible=0 max
  if [ "$which" = 5 ]; then _SL5_RAW=$(( _SL5_RAW + 1 )); max=$RL_MAX_5H
  else _SL7_RAW=$(( _SL7_RAW + 1 )); max=$RL_MAX_7D; fi
  state_limit_name "$name" || return 0
  [ -d "$path" ] && [ ! -L "$path" ] || return 0
  if [ "$_SLN_RST" -gt "$NOW" ] && [ "$_SLN_RST" -le $(( NOW + max )) ]; then plausible=1; fi
  if [ "$which" = 5 ]; then
    i=${#_SL5_NAMES[@]}; _SL5_NAMES[$i]="$name"; _SL5_PATHS[$i]="$path"
    _SL5_RSTS[$i]="$_SLN_RST"; _SL5_PCTS[$i]="$_SLN_PCT"; _SL5_PLAUS[$i]="$plausible"
  else
    i=${#_SL7_NAMES[@]}; _SL7_NAMES[$i]="$name"; _SL7_PATHS[$i]="$path"
    _SL7_RSTS[$i]="$_SLN_RST"; _SL7_PCTS[$i]="$_SLN_PCT"; _SL7_PLAUS[$i]="$plausible"
  fi
}

state_mark_limit_nonempty() {  # $1=5|7 $2=strict parent basename
  local which="$1" name="$2" i
  if [ "$which" = 5 ]; then
    for ((i=0; i<${#_SL5_NAMES[@]}; i++)); do
      [ "${_SL5_NAMES[$i]}" = "$name" ] && _SL5_PLAUS[$i]=0
    done
  else
    for ((i=0; i<${#_SL7_NAMES[@]}; i++)); do
      [ "${_SL7_NAMES[$i]}" = "$name" ] && _SL7_PLAUS[$i]=0
    done
  fi
}

state_add_legacy_record() {
  local record="$1" a b c rest i
  case "$record" in (*$'\t'*$'\t'*) ;; (*) return 1 ;; esac
  a="${record%%$'\t'*}"; rest="${record#*$'\t'}"
  b="${rest%%$'\t'*}"; c="${rest#*$'\t'}"
  case "$c" in (*$'\t'*) return 1 ;; esac
  [[ "$a" =~ ^[0-9]{12}$ ]] && [[ "$b" =~ ^[0-9]{12}$ ]] && [[ "$c" =~ ^[0-9]{1,6}$ ]] || return 1
  [ "$(( 10#$c ))" -le 100000 ] || return 1
  i=${#_LEG_RSTS[@]}
  _LEG_RSTS[$i]=$(( 10#$a )); _LEG_SAMPS[$i]=$(( 10#$b )); _LEG_PCTS[$i]=$(( 10#$c ))
}

state_snapshot() {  # one framed controller for every gated state root + legacy TSV
  local record name phase=paths ctrl=$'\001' f_seen=0 l_seen=0 e_seen=0 bad=0
  local f_status=missing l_status=missing combined=0 matched stream_over=0
  _LEG_RSTS=(); _LEG_SAMPS=(); _LEG_PCTS=()
  exec 9< <(
    if [ "${#_STATE_FIND_ARGS[@]}" -gt 0 ]; then
      LC_ALL=C find -P "${_STATE_FIND_ARGS[@]}" -mindepth 1 -maxdepth 2 -print0 2>/dev/null
      _sf=$?
    else
      _sf=0
    fi
    printf '\001F:%s\0' "$_sf" || exit 0
    if [ "$_STATE_LEGACY_READ" = 1 ]; then
      LC_ALL=C od -An -v -N 1048577 -tu1 -- "$_SB_BASE" 2>/dev/null | LC_ALL=C awk \
        -v now="$NOW" -v maxahead="$RL_MAX_5H" '
        function pct_milli(raw, parts, whole, frac, six, keep, rest, milli, last) {
          if (raw !~ /^(0|[1-9][0-9]?|100)(\.[0-9]{1,6})?$/) return -1
          parts = split(raw, p, "."); whole = p[1]
          frac = (parts == 2 ? p[2] : "")
          if (whole == "100" && frac ~ /[1-9]/) return -1
          six = substr(frac "000000", 1, 6)
          keep = substr(six, 1, 3) + 0; rest = substr(six, 4, 3) + 0
          milli = (whole + 0) * 1000 + keep
          if (rest > 500 || (rest == 500 && milli % 2 == 1)) milli++
          if (milli < 0 || milli > 100000) return -1
          return milli
        }
        function epoch_ok(raw, value) {
          if (raw !~ /^(0|[1-9][0-9]*)$/ || length(raw) > 12) return 0
          if (length(raw) == 12 && raw > "253402300799") return 0
          return 1
        }
        function finish_record( fields, nf, sample, reset, pctm, canon, slot) {
          rows++
          if (rows > 4096) { bad = 1; return }
          if (!row_ascii) { rec = ""; rec_len = 0; row_ascii = 1; return }
          nf = split(rec, fields, "\t")
          if (nf == 3 && epoch_ok(fields[1]) && epoch_ok(fields[3])) {
            sample = fields[1] + 0; reset = fields[3] + 0; pctm = pct_milli(fields[2])
            if (pctm >= 0 && sample <= now + 300 && reset >= sample && reset <= now + maxahead) {
              canon = sprintf("%012d\t%012d\t%d", reset, sample, pctm)
              valid++
              slot = ((valid - 1) % 512) + 1
              ring[slot] = canon
            }
          }
          rec = ""; rec_len = 0; row_ascii = 1
        }
        BEGIN { row_ascii = 1 }
        {
          for (i = 1; i <= NF; i++) {
            byte = $i + 0; bytes++
            if (bytes > 1048576) { bad = 1; exit 42 }
            if (byte == 10) { finish_record(); if (bad) exit 42; continue }
            rec_len++
            if (rec_len > 4096) { bad = 1; exit 42 }
            if (byte == 9 || byte == 46 || (byte >= 48 && byte <= 57)) rec = rec sprintf("%c", byte)
            else row_ascii = 0
          }
        }
        END {
          if (!bad && rec_len > 0) finish_record()
          if (bad) exit 42
          first = valid - 511; if (first < 1) first = 1
          for (i = first; i <= valid; i++) printf "%s%c", ring[((i - 1) % 512) + 1], 0
        }'
      _sp=("${PIPESTATUS[@]}")
      printf '\001L:%s:%s\0' "${_sp[0]}" "${_sp[1]}" || exit 0
    else
      printf '\001L:0:0\0' || exit 0
    fi
    printf '\001E\0'
  )
  while IFS= read -r -d '' -u 9 record; do
    case "$record" in
      ("${ctrl}F:"*)
        [ "$phase" = paths ] && [ "$f_seen" -eq 0 ] || { bad=1; continue; }
        f_seen=1; f_status="${record#?F:}"; phase=legacy
        case "$f_status" in (''|*[!0-9]*) bad=1 ;; esac
        ;;
      ("${ctrl}L:"*)
        [ "$phase" = legacy ] && [ "$l_seen" -eq 0 ] || { bad=1; continue; }
        l_seen=1; l_status="${record#?L:}"; phase=end
        case "$l_status" in ([0-9]*:[0-9]*) ;; (*) bad=1 ;; esac
        ;;
      ("${ctrl}E")
        [ "$phase" = end ] && [ "$e_seen" -eq 0 ] || { bad=1; continue; }
        e_seen=1; phase=done
        ;;
      (/*)
        [ "$phase" = paths ] || { bad=1; continue; }
        combined=$(( combined + 1 )); matched=0
        if [ "$_STATE_BURN_GATE" = 1 ]; then
          case "$record" in ("$_SB_ROOT/./"*/*) matched=1 ;; esac
        fi
        if [ "$matched" -eq 0 ] && [ "$_STATE_RL5_GATE" = 1 ]; then
          case "$record" in
            ("$_SL5_ROOT/./"*/*)
              name="${record#"$_SL5_ROOT/./"}"; name="${name%%/*}"
              state_mark_limit_nonempty 5 "$name"; _SL5_CHILD_RAW=$(( _SL5_CHILD_RAW + 1 )); matched=1
              [ "$_SL5_CHILD_RAW" -le 512 ] || stream_over=1
              ;;
          esac
        fi
        if [ "$matched" -eq 0 ] && [ "$_STATE_RL7_GATE" = 1 ]; then
          case "$record" in
            ("$_SL7_ROOT/./"*/*)
              name="${record#"$_SL7_ROOT/./"}"; name="${name%%/*}"
              state_mark_limit_nonempty 7 "$name"; _SL7_CHILD_RAW=$(( _SL7_CHILD_RAW + 1 )); matched=1
              [ "$_SL7_CHILD_RAW" -le 512 ] || stream_over=1
              ;;
          esac
        fi
        if [ "$matched" -eq 0 ] && [ "$_STATE_BURN_GATE" = 1 ]; then
          case "$record" in ("$_SB_ROOT/./"*) name="${record#"$_SB_ROOT/./"}"; state_add_burn_path "$_SB_ROOT/$name" "$name"; matched=1 ;; esac
          [ "$_SB_RAW" -le 4096 ] || stream_over=1
        fi
        if [ "$matched" -eq 0 ] && [ "$_STATE_RL5_GATE" = 1 ]; then
          case "$record" in ("$_SL5_ROOT/./"*) name="${record#"$_SL5_ROOT/./"}"; state_add_limit_path 5 "$_SL5_ROOT/$name" "$name"; matched=1 ;; esac
          [ "$_SL5_RAW" -le 512 ] || stream_over=1
        fi
        if [ "$matched" -eq 0 ] && [ "$_STATE_RL7_GATE" = 1 ]; then
          case "$record" in ("$_SL7_ROOT/./"*) name="${record#"$_SL7_ROOT/./"}"; state_add_limit_path 7 "$_SL7_ROOT/$name" "$name"; matched=1 ;; esac
          [ "$_SL7_RAW" -le 512 ] || stream_over=1
        fi
        [ "$matched" -eq 1 ] || bad=1
        [ "$combined" -le 5120 ] || stream_over=1
        if [ "$stream_over" -eq 1 ]; then exec 9<&-; break; fi
        ;;
      (*)
        if [ "$phase" = legacy ] && [ "${record:0:1}" != "$ctrl" ]; then
          state_add_legacy_record "$record" || bad=1
        else bad=1; fi
        ;;
    esac
  done
  exec 9<&- 2>/dev/null || true
  if [ "$stream_over" -eq 1 ]; then
    _SB_DIR_COMPLETE=0; _SL5_COMPLETE=0; _SL7_COMPLETE=0; _LEG_COMPLETE=0
    _LEG_RSTS=(); _LEG_SAMPS=(); _LEG_PCTS=()
    return 0
  fi
  [ "$f_seen" -eq 1 ] && [ "$l_seen" -eq 1 ] && [ "$e_seen" -eq 1 ] && [ "$phase" = done ] || bad=1
  [ "$bad" -eq 0 ] || { _SB_DIR_COMPLETE=0; _SL5_COMPLETE=0; _SL7_COMPLETE=0; _LEG_COMPLETE=0; _LEG_RSTS=(); _LEG_SAMPS=(); _LEG_PCTS=(); return 0; }
  if [ "$f_status" = 0 ]; then
    [ "$_SB_DIR_PREOK" = 1 ] && _SB_DIR_COMPLETE=1
    [ "$_SL5_DIR_PREOK" = 1 ] && _SL5_COMPLETE=1
    [ "$_SL7_DIR_PREOK" = 1 ] && _SL7_COMPLETE=1
  fi
  if [ "$l_status" = 0:0 ] && [ "$_LEG_PREOK" = 1 ]; then _LEG_COMPLETE=1
  else _LEG_RSTS=(); _LEG_SAMPS=(); _LEG_PCTS=(); fi
}

state_sort_order() {  # → _SORT_ORDER; stable bottom-up merge sort of _SORT_KEYS
  local n i width left mid right a b k pick LC_ALL=C
  local work=()
  _SORT_ORDER=(); n=${#_SORT_KEYS[@]}
  for ((i=0; i<n; i++)); do _SORT_ORDER[$i]=$i; done
  width=1
  while [ "$width" -lt "$n" ]; do
    work=(); left=0
    while [ "$left" -lt "$n" ]; do
      mid=$(( left + width )); [ "$mid" -gt "$n" ] && mid=$n
      right=$(( left + width + width )); [ "$right" -gt "$n" ] && right=$n
      a=$left; b=$mid; k=$left
      while [ "$a" -lt "$mid" ] || [ "$b" -lt "$right" ]; do
        if [ "$b" -ge "$right" ]; then pick=${_SORT_ORDER[$a]}; a=$(( a + 1 ))
        elif [ "$a" -ge "$mid" ]; then pick=${_SORT_ORDER[$b]}; b=$(( b + 1 ))
        elif [[ "${_SORT_KEYS[${_SORT_ORDER[$b]}]}" < "${_SORT_KEYS[${_SORT_ORDER[$a]}]}" ]]; then
          pick=${_SORT_ORDER[$b]}; b=$(( b + 1 ))
        else pick=${_SORT_ORDER[$a]}; a=$(( a + 1 ))
        fi
        work[$k]=$pick; k=$(( k + 1 ))
      done
      left=$right
    done
    _SORT_ORDER=("${work[@]}"); width=$(( width + width ))
  done
}

state_sort_burn() {
  local i j n
  local names=() paths=() rsts=() samps=() pcts=() plaus=()
  _SORT_KEYS=("${_SB_NAMES[@]}"); state_sort_order; n=${#_SORT_ORDER[@]}
  for ((i=0; i<n; i++)); do
    j=${_SORT_ORDER[$i]}; names[$i]="${_SB_NAMES[$j]}"; paths[$i]="${_SB_PATHS[$j]}"
    rsts[$i]="${_SB_RSTS[$j]}"; samps[$i]="${_SB_SAMPS[$j]}"
    pcts[$i]="${_SB_PCTS[$j]}"; plaus[$i]="${_SB_PLAUS[$j]}"
  done
  _SB_NAMES=("${names[@]}"); _SB_PATHS=("${paths[@]}"); _SB_RSTS=("${rsts[@]}")
  _SB_SAMPS=("${samps[@]}"); _SB_PCTS=("${pcts[@]}"); _SB_PLAUS=("${plaus[@]}")
  _SORT_KEYS=(); _SORT_ORDER=()
}

state_sort_limit() {  # $1=5|7
  local which="$1" i j n
  local names=() paths=() rsts=() pcts=() plaus=()
  if [ "$which" = 5 ]; then _SORT_KEYS=("${_SL5_NAMES[@]}"); else _SORT_KEYS=("${_SL7_NAMES[@]}"); fi
  state_sort_order; n=${#_SORT_ORDER[@]}
  for ((i=0; i<n; i++)); do
    j=${_SORT_ORDER[$i]}
    if [ "$which" = 5 ]; then
      names[$i]="${_SL5_NAMES[$j]}"; paths[$i]="${_SL5_PATHS[$j]}"; rsts[$i]="${_SL5_RSTS[$j]}"
      pcts[$i]="${_SL5_PCTS[$j]}"; plaus[$i]="${_SL5_PLAUS[$j]}"
    else
      names[$i]="${_SL7_NAMES[$j]}"; paths[$i]="${_SL7_PATHS[$j]}"; rsts[$i]="${_SL7_RSTS[$j]}"
      pcts[$i]="${_SL7_PCTS[$j]}"; plaus[$i]="${_SL7_PLAUS[$j]}"
    fi
  done
  if [ "$which" = 5 ]; then
    _SL5_NAMES=("${names[@]}"); _SL5_PATHS=("${paths[@]}"); _SL5_RSTS=("${rsts[@]}")
    _SL5_PCTS=("${pcts[@]}"); _SL5_PLAUS=("${plaus[@]}")
  else
    _SL7_NAMES=("${names[@]}"); _SL7_PATHS=("${paths[@]}"); _SL7_RSTS=("${rsts[@]}")
    _SL7_PCTS=("${pcts[@]}"); _SL7_PLAUS=("${plaus[@]}")
  fi
  _SORT_KEYS=(); _SORT_ORDER=()
}

state_burn_retention() {
  local i n key group_key="" rep=-1 j keep_from reps=0 LC_ALL=C
  local group=() rep_names=() rep_paths=() rep_rsts=() rep_samps=() rep_pcts=()
  _SB_CAND_NAMES=(); _SB_CAND_PATHS=()
  state_sort_burn
  n=${#_SB_NAMES[@]}
  for ((i=0; i<=n; i++)); do
    if [ "$i" -lt "$n" ] && [ "${_SB_PLAUS[$i]}" = 1 ]; then key="${_SB_RSTS[$i]}_${_SB_SAMPS[$i]}"; else key=""; fi
    if [ -n "$group_key" ] && { [ "$key" != "$group_key" ] || [ "$i" -eq "$n" ]; }; then
      for j in "${group[@]}"; do
        if [ "$j" -ne "$rep" ]; then
          _SB_CAND_NAMES[${#_SB_CAND_NAMES[@]}]="${_SB_NAMES[$j]}"
          _SB_CAND_PATHS[${#_SB_CAND_PATHS[@]}]="${_SB_PATHS[$j]}"
        fi
      done
      rep_names[$reps]="${_SB_NAMES[$rep]}"; rep_paths[$reps]="${_SB_PATHS[$rep]}"
      rep_rsts[$reps]="${_SB_RSTS[$rep]}"; rep_samps[$reps]="${_SB_SAMPS[$rep]}"; rep_pcts[$reps]="${_SB_PCTS[$rep]}"
      reps=$(( reps + 1 )); group=(); group_key=""; rep=-1
    fi
    [ "$i" -lt "$n" ] || continue
    if [ "${_SB_PLAUS[$i]}" != 1 ]; then
      _SB_CAND_NAMES[${#_SB_CAND_NAMES[@]}]="${_SB_NAMES[$i]}"
      _SB_CAND_PATHS[${#_SB_CAND_PATHS[@]}]="${_SB_PATHS[$i]}"
      continue
    fi
    key="${_SB_RSTS[$i]}_${_SB_SAMPS[$i]}"
    if [ -z "$group_key" ]; then group_key="$key"; rep=$i; group=($i)
    else
      group[${#group[@]}]=$i
      if [ "${_SB_PCTS[$i]}" -gt "${_SB_PCTS[$rep]}" ] || { [ "${_SB_PCTS[$i]}" -eq "${_SB_PCTS[$rep]}" ] && [[ "${_SB_NAMES[$i]}" < "${_SB_NAMES[$rep]}" ]]; }; then rep=$i; fi
    fi
  done
  keep_from=$(( reps - BURN_TRIM )); [ "$keep_from" -lt 0 ] && keep_from=0
  for ((i=0; i<keep_from; i++)); do
    _SB_CAND_NAMES[${#_SB_CAND_NAMES[@]}]="${rep_names[$i]}"
    _SB_CAND_PATHS[${#_SB_CAND_PATHS[@]}]="${rep_paths[$i]}"
  done
  _SB_REP_RSTS=(); _SB_REP_SAMPS=(); _SB_REP_PCTS=()
  for ((i=0; i<reps; i++)); do
    _SB_REP_RSTS[${#_SB_REP_RSTS[@]}]="${rep_rsts[$i]}"
    _SB_REP_SAMPS[${#_SB_REP_SAMPS[@]}]="${rep_samps[$i]}"
    _SB_REP_PCTS[${#_SB_REP_PCTS[@]}]="${rep_pcts[$i]}"
  done
  _SB_CAND_TOTAL=${#_SB_CAND_PATHS[@]}
}

state_limit_retention() {  # $1=5|7
  local which="$1" i n winner=-1
  state_sort_limit "$which"
  if [ "$which" = 5 ]; then
    _SL5_CAND_NAMES=(); _SL5_CAND_PATHS=(); n=${#_SL5_NAMES[@]}
    for ((i=0; i<n; i++)); do [ "${_SL5_PLAUS[$i]}" = 1 ] && winner=$i; done
    for ((i=0; i<n; i++)); do
      [ "$i" -eq "$winner" ] && continue
      _SL5_CAND_NAMES[${#_SL5_CAND_NAMES[@]}]="${_SL5_NAMES[$i]}"; _SL5_CAND_PATHS[${#_SL5_CAND_PATHS[@]}]="${_SL5_PATHS[$i]}"
    done
    _SL5_CAND_TOTAL=${#_SL5_CAND_PATHS[@]}; _SL5_STORED_VALID=0
    if [ "$winner" -ge 0 ]; then _SL5_STORED_VALID=1; _SL5_STORED_RST="${_SL5_RSTS[$winner]}"; _SL5_STORED_PCT="${_SL5_PCTS[$winner]}"; fi
  else
    _SL7_CAND_NAMES=(); _SL7_CAND_PATHS=(); n=${#_SL7_NAMES[@]}
    for ((i=0; i<n; i++)); do [ "${_SL7_PLAUS[$i]}" = 1 ] && winner=$i; done
    for ((i=0; i<n; i++)); do
      [ "$i" -eq "$winner" ] && continue
      _SL7_CAND_NAMES[${#_SL7_CAND_NAMES[@]}]="${_SL7_NAMES[$i]}"; _SL7_CAND_PATHS[${#_SL7_CAND_PATHS[@]}]="${_SL7_PATHS[$i]}"
    done
    _SL7_CAND_TOTAL=${#_SL7_CAND_PATHS[@]}; _SL7_STORED_VALID=0
    if [ "$winner" -ge 0 ]; then _SL7_STORED_VALID=1; _SL7_STORED_RST="${_SL7_RSTS[$winner]}"; _SL7_STORED_PCT="${_SL7_PCTS[$winner]}"; fi
  fi
}

state_revalidate_burn() {
  local path="$1" name="$2"
  [ "$path" = "$_SB_ROOT/$name" ] || return 1
  state_no_symlink_path "$_SB_ROOT" || return 1
  [ "$_SNP" = "$_SB_ROOT" ] && [ -d "$_SB_ROOT" ] || return 1
  state_burn_name "$name" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ ! -s "$path" ]
}

state_revalidate_limit() {
  local root="$1" path="$2" name="$3"
  [ "$path" = "$root/$name" ] || return 1
  state_no_symlink_path "$root" || return 1
  [ "$_SNP" = "$root" ] && [ -d "$root" ] || return 1
  state_limit_name "$name" || return 1
  [ -d "$path" ] && [ ! -L "$path" ]
}

state_gc() {
  local i limit path name id idx resolved_b=0 resolved_5=0 resolved_7=0
  local rm_paths=() rm_ids=() rm_indexes=()
  _SB_REMOVED=0; _SL5_REMOVED=0; _SL7_REMOVED=0
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SB_COMPLETE" = 1 ]; then
    limit=${#_SB_CAND_PATHS[@]}; [ "$limit" -gt 128 ] && limit=128
    for ((i=0; i<limit; i++)); do
      path="${_SB_CAND_PATHS[$i]}"; name="${_SB_CAND_NAMES[$i]}"
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then resolved_b=$(( resolved_b + 1 ))
      elif state_revalidate_burn "$path" "$name"; then
        idx=${#rm_paths[@]}; rm_paths[$idx]="$path"; rm_ids[$idx]=b; rm_indexes[$idx]=$i
      fi
    done
  fi
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SL5_COMPLETE" = 1 ]; then
    limit=${#_SL5_CAND_PATHS[@]}; [ "$limit" -gt 128 ] && limit=128
    for ((i=0; i<limit; i++)); do
      path="${_SL5_CAND_PATHS[$i]}"; name="${_SL5_CAND_NAMES[$i]}"
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then resolved_5=$(( resolved_5 + 1 ))
      elif state_revalidate_limit "$_SL5_ROOT" "$path" "$name"; then
        idx=${#rm_paths[@]}; rm_paths[$idx]="$path"; rm_ids[$idx]=5; rm_indexes[$idx]=$i
      fi
    done
  fi
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SL7_COMPLETE" = 1 ]; then
    limit=${#_SL7_CAND_PATHS[@]}; [ "$limit" -gt 128 ] && limit=128
    for ((i=0; i<limit; i++)); do
      path="${_SL7_CAND_PATHS[$i]}"; name="${_SL7_CAND_NAMES[$i]}"
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then resolved_7=$(( resolved_7 + 1 ))
      elif state_revalidate_limit "$_SL7_ROOT" "$path" "$name"; then
        idx=${#rm_paths[@]}; rm_paths[$idx]="$path"; rm_ids[$idx]=7; rm_indexes[$idx]=$i
      fi
    done
  fi
  if [ "${#rm_paths[@]}" -gt 0 ]; then rm -df -- "${rm_paths[@]}" 2>/dev/null || true; fi
  for ((i=0; i<${#rm_paths[@]}; i++)); do
    path="${rm_paths[$i]}"; id="${rm_ids[$i]}"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      case "$id" in (b) resolved_b=$(( resolved_b + 1 )) ;; (5) resolved_5=$(( resolved_5 + 1 )) ;; (7) resolved_7=$(( resolved_7 + 1 )) ;; esac
    fi
  done
  _SB_REMOVED=$resolved_b; _SL5_REMOVED=$resolved_5; _SL7_REMOVED=$resolved_7
  _SB_CLEAN=0; _SL5_CLEAN=0; _SL7_CLEAN=0
  [ "$_SB_CAND_TOTAL" -eq "$resolved_b" ] && _SB_CLEAN=1
  [ "$_SL5_CAND_TOTAL" -eq "$resolved_5" ] && _SL5_CLEAN=1
  [ "$_SL7_CAND_TOTAL" -eq "$resolved_7" ] && _SL7_CLEAN=1
}

state_select_limit() {  # $1=5|7, includes the current canonical payload value
  local which="$1" valid=0 rst=0 pct=0 crst cpct
  if [ "$which" = 5 ]; then
    if [ "$_SL5_COMPLETE" = 1 ] && [ "$_SL5_STORED_VALID" = 1 ]; then valid=1; rst=$_SL5_STORED_RST; pct=$_SL5_STORED_PCT; fi
    if [ "$_CUR5_VALID" = 1 ]; then crst=$_CUR5_RST; cpct=$_CUR5_PCT
    else crst=0; cpct=0; fi
  else
    if [ "$_SL7_COMPLETE" = 1 ] && [ "$_SL7_STORED_VALID" = 1 ]; then valid=1; rst=$_SL7_STORED_RST; pct=$_SL7_STORED_PCT; fi
    if [ "$_CUR7_VALID" = 1 ]; then crst=$_CUR7_RST; cpct=$_CUR7_PCT
    else crst=0; cpct=0; fi
  fi
  if [ "$crst" -gt 0 ] && { [ "$valid" -eq 0 ] || [ "$crst" -gt "$rst" ] || { [ "$crst" -eq "$rst" ] && [ "$cpct" -gt "$pct" ]; }; }; then
    valid=1; rst=$crst; pct=$cpct
  fi
  if [ "$which" = 5 ]; then _STATE_RL5_VALID=$valid; _STATE_RL5_RST=$rst; _STATE_RL5_PCT=$pct
  else _STATE_RL7_VALID=$valid; _STATE_RL7_RST=$rst; _STATE_RL7_PCT=$pct; fi
}

state_publish() {
  local raw_post i slot name path
  local mkdir_paths=()
  _PUB_BURN=0; _PUB5=0; _PUB7=0
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SB_COMPLETE" = 1 ] && [ "$_SB_CLEAN" = 1 ] && [ "$_CUR_BURN_VALID" = 1 ]; then
    raw_post=$(( _SB_RAW - _SB_REMOVED ))
    [ "$raw_post" -lt 3968 ] && _PUB_BURN=1
  fi
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SL5_COMPLETE" = 1 ] && [ "$_SL5_CLEAN" = 1 ] && [ "$_CUR5_VALID" = 1 ]; then
    raw_post=$(( _SL5_RAW - _SL5_REMOVED )); [ "$raw_post" -lt 384 ] && _PUB5=1
  fi
  if [ "$_STATE_MUTATE" = 1 ] && [ "$_SL7_COMPLETE" = 1 ] && [ "$_SL7_CLEAN" = 1 ] && [ "$_CUR7_VALID" = 1 ]; then
    raw_post=$(( _SL7_RAW - _SL7_REMOVED )); [ "$raw_post" -lt 384 ] && _PUB7=1
  fi
  if [ "$_PUB_BURN" = 1 ] && [ ! -d "$_SB_ROOT" ]; then
    state_no_symlink_path "$_SB_ROOT" && mkdir_paths[${#mkdir_paths[@]}]="$_SB_ROOT" || _PUB_BURN=0
  fi
  if [ "$_PUB5" = 1 ]; then
    printf -v name '%010d_%03d.%03d' "$_CUR5_RST" $(( _CUR5_PCT / 1000 )) $(( _CUR5_PCT % 1000 ))
    _PUB5_PATH="$_SL5_ROOT/$name"
    state_no_symlink_path "$_PUB5_PATH" && mkdir_paths[${#mkdir_paths[@]}]="$_PUB5_PATH" || _PUB5=0
  fi
  if [ "$_PUB7" = 1 ]; then
    printf -v name '%010d_%03d.%03d' "$_CUR7_RST" $(( _CUR7_PCT / 1000 )) $(( _CUR7_PCT % 1000 ))
    _PUB7_PATH="$_SL7_ROOT/$name"
    state_no_symlink_path "$_PUB7_PATH" && mkdir_paths[${#mkdir_paths[@]}]="$_PUB7_PATH" || _PUB7=0
  fi
  if [ "${#mkdir_paths[@]}" -gt 0 ]; then mkdir -p -- "${mkdir_paths[@]}" 2>/dev/null || true; fi
  if [ "$_PUB5" = 1 ]; then state_revalidate_limit "$_SL5_ROOT" "$_PUB5_PATH" "${_PUB5_PATH##*/}" || _PUB5=0; fi
  if [ "$_PUB7" = 1 ]; then state_revalidate_limit "$_SL7_ROOT" "$_PUB7_PATH" "${_PUB7_PATH##*/}" || _PUB7=0; fi
  if [ "$_PUB_BURN" = 1 ]; then
    state_no_symlink_path "$_SB_ROOT" || _PUB_BURN=0
    [ "$_SNP" = "$_SB_ROOT" ] && [ -d "$_SB_ROOT" ] && [ ! -L "$_SB_ROOT" ] || _PUB_BURN=0
  fi
  if [ "$_PUB_BURN" = 1 ]; then
    set -C
    for ((slot=0; slot<32; slot++)); do
      printf -v name 'b_%012d_%012d_%03d.%03d_%04d' "$_CUR_BURN_RST" "$_CUR_BURN_SAMP" \
        $(( _CUR_BURN_PCT / 1000 )) $(( _CUR_BURN_PCT % 1000 )) "$slot"
      path="$_SB_ROOT/$name"
      if { : > "$path"; } 2>/dev/null; then _PUB_BURN_PATH="$path"; break; fi
      [ -e "$path" ] || [ -L "$path" ] || break
    done
    set +C
  fi
}

state_est_insert() {  # insert one observation into _EST_* ordered by reset/sample/pct
  local rst="$1" samp="$2" pct="$3" key i j n LC_ALL=C
  printf -v key '%012d_%012d_%06d' "$rst" "$samp" "$pct"
  n=${#_EST_KEYS[@]}; j=$n
  while [ "$j" -gt 0 ] && [[ "$key" < "${_EST_KEYS[$((j-1))]}" ]]; do
    _EST_KEYS[$j]="${_EST_KEYS[$((j-1))]}"; _EST_RSTS[$j]="${_EST_RSTS[$((j-1))]}"
    _EST_SAMPS[$j]="${_EST_SAMPS[$((j-1))]}"; _EST_PCTS[$j]="${_EST_PCTS[$((j-1))]}"; j=$(( j - 1 ))
  done
  _EST_KEYS[$j]="$key"; _EST_RSTS[$j]="$rst"; _EST_SAMPS[$j]="$samp"; _EST_PCTS[$j]="$pct"
}

burn_eta_5h() {  # → _B5_STATE _B5_ETA _B5_RATE _B5_TTR from complete state snapshot
  local i n maxrst=0 rst samp pct last_key="" last_samp=-1 last_pct=0
  local a b ct cutoff fc_t=0 fc_p=-1 lc_t=0 lc_p=-1 ncross=0 anycross=0
  local minspan span delta latest_pct=0
  _B5_STATE=warming; _B5_ETA=inf; _B5_RATE="0.0000000000"; _B5_TTR=0
  [ "$_SB_COMPLETE" = 1 ] || return 0
  for ((i=0; i<${#_SB_REP_RSTS[@]}; i++)); do [ "${_SB_REP_RSTS[$i]}" -gt "$maxrst" ] && maxrst="${_SB_REP_RSTS[$i]}"; done
  for ((i=0; i<${#_LEG_RSTS[@]}; i++)); do [ "${_LEG_RSTS[$i]}" -gt "$maxrst" ] && maxrst="${_LEG_RSTS[$i]}"; done
  [ "$_CUR_BURN_VALID" != 1 ] || [ "$_CUR_BURN_RST" -le "$maxrst" ] || maxrst=$_CUR_BURN_RST
  [ "$maxrst" -gt 0 ] || return 0
  _EST_KEYS=(); _EST_RSTS=(); _EST_SAMPS=(); _EST_PCTS=()
  for ((i=0; i<${#_SB_REP_RSTS[@]}; i++)); do
    [ "${_SB_REP_RSTS[$i]}" -eq "$maxrst" ] && state_est_insert "${_SB_REP_RSTS[$i]}" "${_SB_REP_SAMPS[$i]}" "${_SB_REP_PCTS[$i]}"
  done
  for ((i=0; i<${#_LEG_RSTS[@]}; i++)); do
    [ "${_LEG_RSTS[$i]}" -eq "$maxrst" ] && state_est_insert "${_LEG_RSTS[$i]}" "${_LEG_SAMPS[$i]}" "${_LEG_PCTS[$i]}"
  done
  [ "$_CUR_BURN_VALID" != 1 ] || [ "$_CUR_BURN_RST" -ne "$maxrst" ] || state_est_insert "$_CUR_BURN_RST" "$_CUR_BURN_SAMP" "$_CUR_BURN_PCT"
  _SER_SAMPS=(); _SER_PCTS=(); n=${#_EST_KEYS[@]}
  for ((i=0; i<n; i++)); do
    rst="${_EST_RSTS[$i]}"; samp="${_EST_SAMPS[$i]}"; pct="${_EST_PCTS[$i]}"
    key="${rst}_${samp}_${pct}"
    [ "$key" = "$last_key" ] && continue
    last_key="$key"
    if [ "$samp" -ne "$last_samp" ]; then
      _SER_SAMPS[${#_SER_SAMPS[@]}]="$samp"; _SER_PCTS[${#_SER_PCTS[@]}]="$pct"; last_samp=$samp
    elif [ "$pct" -gt "${_SER_PCTS[$(( ${#_SER_PCTS[@]} - 1 ))]}" ]; then
      _SER_PCTS[$(( ${#_SER_PCTS[@]} - 1 ))]="$pct"
    fi
  done
  n=${#_SER_SAMPS[@]}; [ "$n" -gt 0 ] || return 0
  latest_pct="${_SER_PCTS[$((n-1))]}"; _B5_TTR=$(( maxrst - NOW )); [ "$_B5_TTR" -lt 0 ] && _B5_TTR=0
  cutoff=$(( NOW - CORALLINE_BURN_WINDOW )); minspan=$(( CORALLINE_BURN_WINDOW / 10 ))
  for ((i=1; i<n; i++)); do
    a=$(( ${_SER_PCTS[$((i-1))]} / 1000 )); b=$(( ${_SER_PCTS[$i]} / 1000 ))
    if [ "$b" -gt "$a" ]; then
      anycross=1; ct="${_SER_SAMPS[$i]}"
      if [ "$ct" -ge "$cutoff" ] && [ "$ct" -le "$NOW" ]; then
        if [ "$fc_p" -lt 0 ]; then fc_t=$ct; fc_p=$b; fi
        lc_t=$ct; lc_p=$b; ncross=$(( ncross + 1 ))
      fi
    fi
  done
  if [ "$ncross" -ge 2 ] && [ "$lc_t" -gt "$fc_t" ] && [ "$lc_p" -gt "$fc_p" ] && [ $(( lc_t - fc_t )) -ge "$minspan" ]; then
    span=$(( lc_t - fc_t )); delta=$(( lc_p - fc_p ))
    state_rate10 $(( delta * 10000000000 )) "$span"; _B5_RATE="$_RATE10"
    state_round_even $(( (100000 - latest_pct) * span )) $(( delta * 1000 ))
    _B5_ETA=$_RE; _B5_STATE=active
  elif [ "$anycross" -eq 1 ] && [ "$ncross" -eq 0 ]; then _B5_STATE=idle
  fi
}

burn_eta_7d() {  # → _B7_*; $1=pct_milli $2=reset epoch
  local pct="${1:-}" rst="${2:-}" elapsed
  _B7_ETA=inf; _B7_RATE="0.0000000000"; _B7_TTR=0
  [ -n "$pct" ] && [ -n "$rst" ] || return 0
  _B7_TTR=$(( rst - NOW )); [ "$_B7_TTR" -lt 0 ] && _B7_TTR=0
  elapsed=$(( NOW - (rst - 604800) ))
  [ "$pct" -gt 0 ] && [ "$elapsed" -ge 1 ] && [ "$elapsed" -le "$RL_MAX_7D" ] || return 0
  state_rate10 $(( pct * 10000000 )) "$elapsed"; _B7_RATE="$_RATE10"
  state_round_even $(( (100000 - pct) * elapsed )) "$pct"; _B7_ETA=$_RE
}

burn_estimate() {  # → _BURN_STATE _BURN_LABEL _BURN_ETA _BURN_RATE _BURN_TTR
  local f5=0 f7=0
  [ "$_B5_ETA" != inf ] && f5=1
  [ "$_B7_ETA" != inf ] && f7=1
  if [ "$f5" = 1 ] && { [ "$f7" = 0 ] || [ "$_B5_ETA" -le "$_B7_ETA" ]; }; then
    _BURN_STATE=active; _BURN_LABEL=5h; _BURN_ETA=$_B5_ETA; _BURN_RATE=$_B5_RATE; _BURN_TTR=$_B5_TTR
  elif [ "$f7" = 1 ]; then
    _BURN_STATE=active; _BURN_LABEL=7d; _BURN_ETA=$_B7_ETA; _BURN_RATE=$_B7_RATE; _BURN_TTR=$_B7_TTR
  else
    _BURN_ETA=inf; _BURN_RATE="0.0000000000"; _BURN_TTR=0; _BURN_LABEL=""
    if [ "$_B5_STATE" = idle ]; then _BURN_STATE=idle; else _BURN_STATE=warming; fi
  fi
}

state_prepare() {  # one state snapshot/GC/publication/estimate pass per render
  local root i
  _STATE_MUTATE=1; [ "${CORALLINE_NO_SAMPLE:-0}" = 1 ] && _STATE_MUTATE=0
  RL_MAX_5H=21600; RL_MAX_7D=691200
  case "$CORALLINE_BURN_WINDOW" in (''|*[!0-9]*) CORALLINE_BURN_WINDOW=600 ;; esac
  [ "${#CORALLINE_BURN_WINDOW}" -le 5 ] && [ "$CORALLINE_BURN_WINDOW" -ge 60 ] 2>/dev/null \
    && [ "$CORALLINE_BURN_WINDOW" -le 86400 ] 2>/dev/null || CORALLINE_BURN_WINDOW=600
  case "$BURN_TRIM" in (''|*[!0-9]*) BURN_TRIM=1500 ;; esac
  [ "${#BURN_TRIM}" -le 4 ] && [ "$BURN_TRIM" -ge 1 ] 2>/dev/null \
    && [ "$BURN_TRIM" -le 3000 ] 2>/dev/null || BURN_TRIM=1500

  _CUR5_VALID=0; _CUR7_VALID=0; _CUR_BURN_VALID=0
  if state_pct "$fh_pct"; then
    _CUR5_PCT=$_SP_MILLI
    if state_payload_epoch "$fh_rst" 10; then
      _CUR5_RST=$_SE_VALUE; _CUR5_RST_PAD=$_SE_PAD
      [ "$_CUR5_RST" -gt "$NOW" ] && [ "$_CUR5_RST" -le $(( NOW + RL_MAX_5H )) ] && _CUR5_VALID=1
    fi
  fi
  if state_pct "$wd_pct"; then
    _CUR7_PCT=$_SP_MILLI
    if state_payload_epoch "$wd_rst" 10; then
      _CUR7_RST=$_SE_VALUE; _CUR7_RST_PAD=$_SE_PAD
      [ "$_CUR7_RST" -gt "$NOW" ] && [ "$_CUR7_RST" -le $(( NOW + RL_MAX_7D )) ] && _CUR7_VALID=1
    fi
  fi
  if [ "$_CUR5_VALID" = 1 ]; then
    state_epoch "$NOW" 12
    _CUR_BURN_SAMP=$_SE_VALUE; _CUR_BURN_SAMP_PAD=$_SE_PAD
    _CUR_BURN_RST=$_CUR5_RST; _CUR_BURN_PCT=$_CUR5_PCT
    [ "$_CUR_BURN_SAMP" -le $(( NOW + 300 )) ] && [ "$_CUR_BURN_RST" -ge "$_CUR_BURN_SAMP" ] && _CUR_BURN_VALID=1
  fi

  _SB_NAMES=(); _SB_PATHS=(); _SB_RSTS=(); _SB_SAMPS=(); _SB_PCTS=(); _SB_PLAUS=(); _SB_RAW=0
  _SL5_NAMES=(); _SL5_PATHS=(); _SL5_RSTS=(); _SL5_PCTS=(); _SL5_PLAUS=(); _SL5_RAW=0; _SL5_CHILD_RAW=0
  _SL7_NAMES=(); _SL7_PATHS=(); _SL7_RSTS=(); _SL7_PCTS=(); _SL7_PLAUS=(); _SL7_RAW=0; _SL7_CHILD_RAW=0
  _STATE_FIND_ARGS=(); _STATE_LEGACY_READ=0
  _SB_DIR_PREOK=1; _SL5_DIR_PREOK=1; _SL7_DIR_PREOK=1; _LEG_PREOK=1
  _SB_DIR_COMPLETE=0; _SL5_COMPLETE=0; _SL7_COMPLETE=0; _LEG_COMPLETE=0; _SB_COMPLETE=0

  if [ "$_STATE_BURN_GATE" = 1 ]; then
    if state_store_path "$BURN_FILE"; then _SB_BASE=$_SS_BASE; _SB_ROOT=$_SS_ROOT
    else _SB_DIR_PREOK=0; _LEG_PREOK=0; fi
    if [ "$_SB_DIR_PREOK" = 1 ]; then
      state_no_symlink_path "$_SB_ROOT" || _SB_DIR_PREOK=0
      if [ "$_SB_DIR_PREOK" = 1 ] && { [ -e "$_SB_ROOT" ] || [ -L "$_SB_ROOT" ]; }; then
        [ -d "$_SB_ROOT" ] && [ ! -L "$_SB_ROOT" ] || _SB_DIR_PREOK=0
        [ "$_SB_DIR_PREOK" = 0 ] || _STATE_FIND_ARGS[${#_STATE_FIND_ARGS[@]}]="$_SB_ROOT/."
      fi
      state_no_symlink_path "$_SB_BASE" || _LEG_PREOK=0
      if [ "$_LEG_PREOK" = 1 ] && { [ -e "$_SB_BASE" ] || [ -L "$_SB_BASE" ]; }; then
        [ -f "$_SB_BASE" ] && [ ! -L "$_SB_BASE" ] || _LEG_PREOK=0
        [ "$_LEG_PREOK" = 0 ] || _STATE_LEGACY_READ=1
      fi
    fi
  fi
  if [ "$_STATE_RL5_GATE" = 1 ]; then
    if state_store_path "$RL5H_FILE"; then _SL5_ROOT=$_SS_ROOT; else _SL5_DIR_PREOK=0; fi
    if [ "$_SL5_DIR_PREOK" = 1 ]; then
      state_no_symlink_path "$_SL5_ROOT" || _SL5_DIR_PREOK=0
      if [ "$_SL5_DIR_PREOK" = 1 ] && { [ -e "$_SL5_ROOT" ] || [ -L "$_SL5_ROOT" ]; }; then
        [ -d "$_SL5_ROOT" ] && [ ! -L "$_SL5_ROOT" ] || _SL5_DIR_PREOK=0
        [ "$_SL5_DIR_PREOK" = 0 ] || _STATE_FIND_ARGS[${#_STATE_FIND_ARGS[@]}]="$_SL5_ROOT/."
      fi
    fi
  fi
  if [ "$_STATE_RL7_GATE" = 1 ]; then
    if state_store_path "$RL7D_FILE"; then _SL7_ROOT=$_SS_ROOT; else _SL7_DIR_PREOK=0; fi
    if [ "$_SL7_DIR_PREOK" = 1 ]; then
      state_no_symlink_path "$_SL7_ROOT" || _SL7_DIR_PREOK=0
      if [ "$_SL7_DIR_PREOK" = 1 ] && { [ -e "$_SL7_ROOT" ] || [ -L "$_SL7_ROOT" ]; }; then
        [ -d "$_SL7_ROOT" ] && [ ! -L "$_SL7_ROOT" ] || _SL7_DIR_PREOK=0
        [ "$_SL7_DIR_PREOK" = 0 ] || _STATE_FIND_ARGS[${#_STATE_FIND_ARGS[@]}]="$_SL7_ROOT/."
      fi
    fi
  fi
  if [ "$_STATE_BURN_GATE" = 1 ] && [ "$_STATE_RL5_GATE" = 1 ] && state_same_path "$_SB_ROOT" "$_SL5_ROOT"; then _SB_DIR_PREOK=0; _SL5_DIR_PREOK=0; fi
  if [ "$_STATE_BURN_GATE" = 1 ] && [ "$_STATE_RL7_GATE" = 1 ] && state_same_path "$_SB_ROOT" "$_SL7_ROOT"; then _SB_DIR_PREOK=0; _SL7_DIR_PREOK=0; fi
  if [ "$_STATE_RL5_GATE" = 1 ] && [ "$_STATE_RL7_GATE" = 1 ] && state_same_path "$_SL5_ROOT" "$_SL7_ROOT"; then _SL5_DIR_PREOK=0; _SL7_DIR_PREOK=0; fi

  state_snapshot
  if [ "$_STATE_BURN_GATE" = 1 ]; then [ "$_SB_DIR_COMPLETE" = 1 ] && [ "$_LEG_COMPLETE" = 1 ] && _SB_COMPLETE=1; fi
  if [ "$_SB_COMPLETE" = 1 ]; then state_burn_retention; else _SB_CAND_NAMES=(); _SB_CAND_PATHS=(); _SB_CAND_TOTAL=0; _SB_REP_RSTS=(); _SB_REP_SAMPS=(); _SB_REP_PCTS=(); fi
  if [ "$_SL5_COMPLETE" = 1 ]; then state_limit_retention 5; else _SL5_CAND_NAMES=(); _SL5_CAND_PATHS=(); _SL5_CAND_TOTAL=0; _SL5_STORED_VALID=0; fi
  if [ "$_SL7_COMPLETE" = 1 ]; then state_limit_retention 7; else _SL7_CAND_NAMES=(); _SL7_CAND_PATHS=(); _SL7_CAND_TOTAL=0; _SL7_STORED_VALID=0; fi
  state_gc
  state_select_limit 5; state_select_limit 7
  state_publish
  burn_eta_5h
  if [ "$VL_LIMIT_SYNC" = 1 ] && [ "$_STATE_RL7_VALID" = 1 ]; then burn_eta_7d "$_STATE_RL7_PCT" "$_STATE_RL7_RST"
  elif [ "$_CUR7_VALID" = 1 ]; then burn_eta_7d "$_CUR7_PCT" "$_CUR7_RST"
  else burn_eta_7d "" ""; fi
  burn_estimate
  _STATE_READY=1
}

seg_burn() {  # range-to-empty ETA until the binding 5h/7d limit hits 100% at the recent burn rate
  if [ "${_STATE_READY:-0}" = 1 ]; then
    [ "${_CUR5_VALID:-0}" = 1 ] || [ "${_CUR7_VALID:-0}" = 1 ] || return 0
  else
    [ -n "$fh_pct" ] || [ -n "$wd_pct" ] || return 0
  fi
  # _BURN_* is precomputed once per render (see the burn_estimate call beside the
  # sampler below), so the visible and float passes share one computation.
  local bg="${VL_BG_BURN:-$VL_BG_5H}"
  # Nothing to project yet. Idle (stopped burning) is genuinely all-good → dim ✓.
  # Warming (no samples yet, e.g. a fresh install) is "unknown", not healthy → a
  # distinct dim … so a cold start doesn't read as a reassuring green check.
  if [ "$_BURN_STATE" != "active" ]; then
    fg "$VL_FG_DIM"
    if [ "$_BURN_STATE" = "warming" ]; then
      push "$bg" "${_FG} ${VL_BURN_GLYPH} … "
    else
      push "$bg" "${_FG} ${VL_BURN_GLYPH} ✓ "
    fi
    return 0
  fi
  local eta="$_BURN_ETA" ttr="$_BURN_TTR" col win
  # All good: the projected empty is longer than the limit's whole window, so at
  # this pace you couldn't run it dry even from a fresh window — show ✓, not a
  # meaningless multi-day countdown. The window is per-limit (5h vs 7d).
  case "$_BURN_LABEL" in 5h) win=18000 ;; *) win=604800 ;; esac
  if [ "$eta" -gt "$win" ]; then
    fg "$VL_FG_OK"
    push "$bg" "${_FG} ${VL_BURN_GLYPH} ✓ "
    return 0
  fi
  if   [ "$eta" -le "$ttr" ];               then col="$VL_FG_HOT"
  elif [ $(( 10 * ttr )) -ge $(( 8 * eta )) ]; then col="$VL_FG_WARN"
  else                                            col="$VL_FG_OK"; fi
  fmt_eta "$eta"
  fg "$col"
  push "$bg" "${_FG} ${VL_BURN_GLYPH} ${_BURN_LABEL} ⇢ ${_ETA} "
}

pct_fg() {  # → _PFG (a color spec) ; $1=pct
  local pct="${1:-0}"
  if   [ "$pct" -ge "$VL_HOT_PCT" ];  then _PFG="$VL_FG_HOT"
  elif [ "$pct" -ge "$VL_WARN_PCT" ]; then _PFG="$VL_FG_WARN"
  else                                     _PFG="$VL_FG_OK"; fi
}

trunc() {  # → _TR ; $1 clipped to $2 visible chars, middle-truncated with … ; $2=0 → unchanged
  local s="$1" max="${2:-0}" head tail start
  case "$max" in (''|*[!0-9]*) max=0 ;; esac
  if [ "$max" -le 0 ] || [ "${#s}" -le "$max" ]; then _TR="$s"; return; fi
  if [ "$max" -lt 3 ]; then _TR="${s:0:max}"; return; fi   # no room for head+…+tail
  # Keep head and tail so names sharing a long prefix stay distinguishable.
  head=$(( (max - 1) / 2 )); tail=$(( max - 1 - head )); start=$(( ${#s} - tail ))
  _TR="${s:0:head}…${s:start}"
}

now_strftime() {  # → _T ; $1=strftime fmt. Fork-free on bash 4.2+, one date call on 3.2.
  # Force C locale so %p is AM/PM (matched/lowercased by the caller), not localized.
  LC_ALL=C printf -v _T "%($1)T" -1 2>/dev/null || _T=$(LC_ALL=C date "+$1")
}

# JSON-string escape for the --subagent output protocol → _JS. Pure bash so the
# per-row loop stays fork-free. Escapes \ " and the JSON control shorthands,
# maps ESC to \u001b (ANSI colors survive the round-trip), drops any other
# control character. Untrusted panel fields are scrubbed at the jq extraction
# (see the --subagent block), so the ESC mapping only sees our own codes.
json_escape() {
  local s="$1" out="" c i n
  case "$s" in
    (*[\"\\[:cntrl:]]*) ;;
    (*) _JS="$s"; return 0 ;;
  esac
  n=${#s}
  for ((i=0; i<n; i++)); do
    c="${s:i:1}"
    case "$c" in
      '"')     out+='\"'      ;;
      '\')     out+='\\'      ;;
      $'\033') out+='\u001b'  ;;
      $'\t')   out+='\t'      ;;
      $'\n')   out+='\n'      ;;
      $'\r')   out+='\r'      ;;
      [[:cntrl:]]) ;;
      *)       out+="$c"      ;;
    esac
  done
  _JS="$out"
}

# Resolved model ID → short display name → _MS. The subagent panel's per-task
# model is an ID (claude-haiku-4-5-20251001), not the main statusline's
# display_name. Strip claude- and a trailing date stamp, dot the version, map
# the known families (bash 3.2 has no ${var^}). Anything unrecognized passes
# through verbatim — never wrong, merely verbose.
model_short() {
  local s="$1" fam ver
  _MS="$1"
  case "$s" in (claude-*) ;; (*) return 0 ;; esac
  s="${s#claude-}"
  case "$s" in (*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) s="${s%-*}" ;; esac
  fam="${s%%-*}" ; ver="${s#"$fam"}" ; ver="${ver#-}"
  case "$ver" in (''|*[!0-9-]*) return 0 ;; esac
  case "$fam" in
    (fable)  fam="Fable"  ;;
    (opus)   fam="Opus"   ;;
    (sonnet) fam="Sonnet" ;;
    (haiku)  fam="Haiku"  ;;
    (*) return 0 ;;
  esac
  _MS="$fam ${ver//-/.}"
}

# ── Git state (single subprocess, parsed once, used by git/stash segments) ──
# All git below is read-only probing. Disable git's optional index lock so a
# frequently-refreshed statusline never rewrites the index or contends for
# index.lock with a real git operation (notably on Windows). Set once, inherited
# by every git call here.
export GIT_OPTIONAL_LOCKS=0
GIT_BRANCH="" GIT_MARKS="" GIT_AB="" GIT_DIRTY=0 GIT_ROOT=""
read_git() {
  local line oid="" head="" a="" b="" staged=0 unstaged=0 untracked=0
  [ -n "$cwd" ] || return
  while IFS= read -r line; do
    case "$line" in
      "# branch.oid "*)      oid="${line#\# branch.oid }" ;;
      "# branch.head "*)     head="${line#\# branch.head }" ;;
      "# branch.ab "*)       set -- ${line#\# branch.ab }; a="${1#+}"; b="${2#-}" ;;
      "? "*)                 untracked=1 ;;
      [12]" "*)              line="${line#? }"
                             case "${line:0:1}" in [!.]) staged=1 ;; esac
                             case "${line:1:1}" in [!.]) unstaged=1 ;; esac ;;
      "u "*)                 unstaged=1 ;;
    esac
  done <<GIT
$(git -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)
GIT
  [ -z "$oid" ] && return                     # not a repo
  if [ "$head" = "(detached)" ] || [ -z "$head" ]; then
    GIT_BRANCH="${oid:0:7}"
  else
    GIT_BRANCH="$head"
  fi
  # Stable project name (seg_project): basename of the MAIN repo root, which is
  # shared by every linked worktree — so it stays constant whichever worktree
  # you're in. Resolved only when the project segment is enabled, to keep the
  # one-git-call default untouched.
  case "$_SEG_SCAN" in *" project "*)
    local cdir
    cdir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ -n "$cdir" ] || cdir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$cdir" ]; then
      cdir="${cdir%/}" ; cdir="${cdir%/.git}"
      GIT_ROOT="${cdir##*/}"
    fi ;;
  esac
  [ "$staged"    -eq 1 ] && GIT_MARKS="${GIT_MARKS}+"
  [ "$unstaged"  -eq 1 ] && GIT_MARKS="${GIT_MARKS}!"
  [ "$untracked" -eq 1 ] && GIT_MARKS="${GIT_MARKS}?"
  [ "${a:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇡${a}"
  [ "${b:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇣${b}"
  [ -n "$GIT_MARKS" ] && GIT_DIRTY=1
}
# ── Segments ─────────────────────────────────────────────────────────────────
# Each seg_* appends (background, text, visible width) to the segment arrays.
ESC=$'\033'
# Visible DISPLAY WIDTH (terminal columns) of $1, ANSI stripped → SEG_LEN_R.
# Decodes UTF-8 straight from the bytes (LC_ALL=C forced locally) so the count is
# correct no matter what $LANG is. This matters: Git Bash usually leaves LANG empty,
# where ${#s} counts *bytes* — a 5-glyph "▰▰▰▱▱" bar then reads as 15 and a CJK path
# char as 3, inflating every segment so the auto-layout wrap fires far too early.
# Wide CJK / kana / Hangul / fullwidth / emoji code points count as 2 columns,
# combining and zero-width marks as 0, everything else as 1. Pure bash, no subprocess.
seg_len() {
  local s="$1" plain="" LC_ALL=C n i b cp c2 c3 c4 w=0
  while [ "${s#*$ESC}" != "$s" ]; do          # strip CSI "...m" color escapes
    plain+="${s%%$ESC*}"
    s="${s#*$ESC}" ; s="${s#*m}"
  done
  plain+="$s"
  n=${#plain} ; i=0
  while [ "$i" -lt "$n" ]; do
    printf -v b '%d' "'${plain:i:1}" ; [ "$b" -lt 0 ] && b=$((b + 256))
    if   [ "$b" -lt 192 ]; then cp=$b ; i=$((i + 1))                  # ASCII / stray byte
    elif [ "$b" -lt 224 ]; then                                      # 2-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      cp=$(( (b - 192) * 64 + (c2 - 128) )) ; i=$((i + 2))
    elif [ "$b" -lt 240 ]; then                                      # 3-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      printf -v c3 '%d' "'${plain:i+2:1}" ; [ "$c3" -lt 0 ] && c3=$((c3 + 256))
      cp=$(( (b - 224) * 4096 + (c2 - 128) * 64 + (c3 - 128) )) ; i=$((i + 3))
    else                                                             # 4-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      printf -v c3 '%d' "'${plain:i+2:1}" ; [ "$c3" -lt 0 ] && c3=$((c3 + 256))
      printf -v c4 '%d' "'${plain:i+3:1}" ; [ "$c4" -lt 0 ] && c4=$((c4 + 256))
      cp=$(( (b - 240) * 262144 + (c2 - 128) * 4096 + (c3 - 128) * 64 + (c4 - 128) )) ; i=$((i + 4))
    fi
    if [ "$cp" -lt 768 ]; then w=$((w + 1)) ; continue ; fi          # ASCII + Latin fast path
    if   { [ "$cp" -ge 768 ]   && [ "$cp" -le 879 ]; }   \
      || { [ "$cp" -ge 8203 ]  && [ "$cp" -le 8207 ]; }  \
      || { [ "$cp" -ge 65024 ] && [ "$cp" -le 65039 ]; }; then
      :                                                              # combining / ZWSP / variation selector → 0 cols
    elif { [ "$cp" -ge 4352 ]   && [ "$cp" -le 4447 ]; }   \
      || { [ "$cp" -ge 11904 ]  && [ "$cp" -le 42191 ]; }  \
      || { [ "$cp" -ge 44032 ]  && [ "$cp" -le 55203 ]; }  \
      || { [ "$cp" -ge 63744 ]  && [ "$cp" -le 64255 ]; }  \
      || { [ "$cp" -ge 65040 ]  && [ "$cp" -le 65049 ]; }  \
      || { [ "$cp" -ge 65072 ]  && [ "$cp" -le 65103 ]; }  \
      || { [ "$cp" -ge 65280 ]  && [ "$cp" -le 65376 ]; }  \
      || { [ "$cp" -ge 65504 ]  && [ "$cp" -le 65510 ]; }  \
      || { [ "$cp" -ge 127744 ] && [ "$cp" -le 129791 ]; } \
      || { [ "$cp" -ge 131072 ] && [ "$cp" -le 262143 ]; }; then
      w=$((w + 2))                                                   # East-Asian wide / fullwidth / emoji → 2 cols
    else
      w=$((w + 1))
    fi
  done
  SEG_LEN_R=$w
}
push() {
  # SEG_LEN[] is read only by the auto-layout wrap; fixed-layout print_range never
  # touches it, so skip the per-char width scan entirely outside auto layout.
  if [ "$VL_LAYOUT" = "auto" ]; then seg_len "$2" ; else SEG_LEN_R=0 ; fi
  SEG_BGS[${#SEG_BGS[@]}]="$1"
  SEG_TXT[${#SEG_TXT[@]}]="$2"
  SEG_LEN[${#SEG_LEN[@]}]="$SEG_LEN_R"
}

seg_project() {  # repo-root name in a repo; falls back to dir outside one (unless dir is already shown)
  if [ -z "$GIT_ROOT" ]; then
    case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" dir "*) return 0 ;; esac
    seg_dir; return
  fi
  fg "$VL_FG_TEXT"; trunc "$GIT_ROOT" "$VL_NAME_MAX"
  push "${VL_BG_PROJECT:-$VL_BG_DIR}" "${BOLD}${_FG} ${VL_PROJECT_GLYPH} ${_TR} ${NORM}"
}

seg_dir() {  # current directory, long paths collapsed to ~/a/…/z
  [ -n "$cwd" ] || return 0
  local tilde='~'; local short="${cwd/#"$HOME"/$tilde}" n last
  local IFS='/'; set -- $short; n=$#
  if [ "$n" -gt "$VL_PATH_DEPTH" ]; then
    eval "last=\${$n}"
    short="$1/$2/…/$last"
  fi
  fg "$VL_FG_TEXT"
  push "$VL_BG_DIR" "${BOLD}${_FG} ${short} ${NORM}"
}

seg_git() {  # branch with staged/modified/untracked and ahead/behind counts
  [ -n "$GIT_BRANCH" ] || return 0
  local bgc="$VL_BG_GIT_OK"
  [ "$GIT_DIRTY" -eq 1 ] && bgc="$VL_BG_GIT_DIRTY"
  fg "$VL_FG_TEXT"; trunc "$GIT_BRANCH" "$VL_NAME_MAX"
  push "$bgc" "${BOLD}${_FG} ⎇ ${_TR}${GIT_MARKS}${GIT_AB} ${NORM}"
}

seg_model() {  # active Claude model
  [ -n "$model" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_MODEL" "${BOLD}${_FG} ◆ ${model#Claude } ${NORM}"
}

seg_ctx() {  # context-window gauge with input/output/cache token counts
  [ -n "$ctx_pct" ] || return 0
  local ci fgc fgd ti to tcr tcw
  printf -v ci '%.0f' "$ctx_pct" 2>/dev/null || ci=0
  make_bar "$ci"; pct_fg "$ci"
  fg "$_PFG";       fgc="$_FG"
  fg "$VL_FG_DIM";  fgd="$_FG"
  fmt_tok "$tok_in"; ti="$_TOK"
  fmt_tok "$tok_out"; to="$_TOK"
  fmt_tok "$tok_cr"; tcr="$_TOK"
  fmt_tok "$tok_cw"; tcw="$_TOK"
  push "$VL_BG_CTX" "${fgc} ${VL_CTX_GLYPH} ${_BAR} ${ci}% ${fgd}↑${ti} ↓${to} cr:${tcr} cw:${tcw} "
}

seg_limit() {  # $1=label $2=pct $3=resets_at $4=bg $5=canonical pct_milli(optional)
  [ -n "$2" ] || return 0
  local v fgc rst=""
  if [ -n "${5:-}" ]; then state_round_even "$5" 1000; v=$_RE
  else printf -v v '%.0f' "$2" 2>/dev/null || v=0; fi
  make_bar "$v"; pct_fg "$v"
  fg "$_PFG"; fgc="$_FG"
  fmt_countdown "$3"
  if [ -n "$_CD" ]; then fg "$VL_FG_DIM"; rst="${_FG}↺${_CD}"; fi
  push "$4" "${fgc} $1 ${_BAR} ${v}% ${rst} "
}
# With VL_LIMIT_SYNC, render the once-per-render canonical state result.
seg_limit5h() {  # 5h rate-limit gauge with reset countdown
  local p="$fh_pct" r="$fh_rst" m=""
  if [ "$VL_LIMIT_SYNC" = 1 ]; then
    [ "${_STATE_RL5_VALID:-0}" = 1 ] || return 0
    m=$_STATE_RL5_PCT; printf -v p '%d.%03d' $(( m / 1000 )) $(( m % 1000 )); r=$_STATE_RL5_RST
  fi
  seg_limit "5h" "$p" "$r" "$VL_BG_5H" "$m"
}
seg_limit7d() {  # 7d rate-limit gauge with reset countdown
  local p="$wd_pct" r="$wd_rst" m=""
  if [ "$VL_LIMIT_SYNC" = 1 ]; then
    [ "${_STATE_RL7_VALID:-0}" = 1 ] || return 0
    m=$_STATE_RL7_PCT; printf -v p '%d.%03d' $(( m / 1000 )) $(( m % 1000 )); r=$_STATE_RL7_RST
  fi
  seg_limit "7d" "$p" "$r" "$VL_BG_7D" "$m"
}

seg_cost() {  # session cost in USD
  [ -n "$cost" ] && [ "$cost" != "0" ] || return 0
  local fmt
  printf -v fmt "\$%.${VL_COST_DECIMALS}f" "$cost" 2>/dev/null || fmt="\$$cost"
  fg "$VL_FG_TEXT"
  push "$VL_BG_COST" "${_FG} ${fmt} "
}

seg_clock() {  # time, 12h or 24h
  [ "$VL_CLOCK" = "off" ] && return 0
  if [ "$VL_CLOCK" = "24h" ]; then
    [ "$VL_CLOCK_SECONDS" = "1" ] && now_strftime '%H:%M:%S' || now_strftime '%H:%M'
  else
    [ "$VL_CLOCK_SECONDS" = "1" ] && now_strftime '%I:%M:%S %p' || now_strftime '%I:%M %p'
    case "$_T" in *AM) _T="${_T% AM} am" ;; *PM) _T="${_T% PM} pm" ;; esac
  fi
  fg "$VL_FG_TEXT"
  push "$VL_BG_CLOCK" "${_FG} ⊙ ${_T} "
}

seg_lines() {  # lines added/removed this session
  [ "${lines_add:-0}" -gt 0 ] 2>/dev/null || [ "${lines_del:-0}" -gt 0 ] 2>/dev/null || return 0
  local fgo fgh
  fg "$VL_FG_OK";  fgo="$_FG"
  fg "$VL_FG_HOT"; fgh="$_FG"
  push "$VL_BG_LINES" " ${fgo}+${lines_add} ${fgh}-${lines_del} "
}

seg_style() {  # active output style
  [ -n "$out_style" ] && [ "$out_style" != "default" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_STYLE" "${_FG} ✎ ${out_style} "
}

seg_duration() {  # session wall-clock duration
  [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null || return 0
  fmt_duration "$dur_ms"
  fg "$VL_FG_TEXT"
  push "$VL_BG_DURATION" "${_FG} ⧖ ${_DUR} "
}

seg_effort() {  # reasoning effort level (low/medium/high/xhigh/max); glyph ψ is editable
  [ -n "$effort" ] || return 0
  local label="$effort"
  case "$effort" in (medium) label="med" ;; esac
  fg "$VL_FG_TEXT"
  push "$VL_BG_EFFORT" "${_FG} ψ ${label} "
}

seg_stash() {  # git stash count
  [ -n "$GIT_BRANCH" ] || return 0
  local n
  n=$(git -C "$cwd" rev-list --walk-reflogs --count refs/stash 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_STASH:-$VL_BG_GIT_OK}" "${_FG} ⚑ ${n} "
}

# ── Runtime detection (node / python segments) ───────────────────────────────
# Each sets the global _RT to a label for directory $1 (empty when nothing is
# detected), so the seg_* callers read a global instead of a $() subshell — the
# fork-free convention used by fg/_FG, trunc/_TR, seg_len/SEG_LEN_R.
#
# The pin-file path (.nvmrc / .python-version, walking up ancestors) is always
# tried first and never forks. The interpreter probe DOES fork, so it is gated
# behind VL_RUNTIME_PROBE, off by default (set it to 1 to detect e.g. nvm's
# active version in a repo with no pin file).
#
# Notes: `read` returns non-zero at EOF on a newline-less pin file, but $v IS
# set — so pre-clear and ignore read's status rather than `|| v=""`, which would
# discard the value. `[ -f ]` (not `[ -r ]`) so a directory named .nvmrc does
# not match and make `read` emit "Is a directory". The walk uses `case */*` to
# step up, since ${dir%/*} is a no-op once no slash is left and would otherwise
# spin forever on a relative/slash-less argument.
runtime_node() {  # -> _RT: active Node version label for directory $1
  local dir="$1" f v
  _RT=""
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    for f in .nvmrc .node-version; do
      if [ -f "$dir/$f" ]; then
        v=""; IFS= read -r v < "$dir/$f"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        [ -n "$v" ] && { _RT="${v#v}"; return 0; }   # normalize v20.x -> 20.x
      fi
    done
    case "$dir" in */*) dir="${dir%/*}" ;; *) break ;; esac
  done
  if [ "${VL_RUNTIME_PROBE:-0}" = "1" ] && command -v node >/dev/null 2>&1; then
    v=$(node --version 2>/dev/null) && [ -n "$v" ] && _RT="${v#v}"
  fi
}

runtime_python() {  # -> _RT: active Python env/version label for directory $1
  local dir="$1" v
  _RT=""
  [ -n "${VIRTUAL_ENV:-}" ] && { _RT="${VIRTUAL_ENV##*/}"; return 0; }
  # conda auto-activates `base` for most users, so it is not a meaningful "env".
  [ -n "${CONDA_DEFAULT_ENV:-}" ] && [ "$CONDA_DEFAULT_ENV" != base ] \
    && { _RT="$CONDA_DEFAULT_ENV"; return 0; }
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.python-version" ]; then
      v=""; IFS= read -r v < "$dir/.python-version"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      [ -n "$v" ] && { _RT="$v"; return 0; }
    fi
    case "$dir" in */*) dir="${dir%/*}" ;; *) break ;; esac
  done
  if [ "${VL_RUNTIME_PROBE:-0}" = "1" ] && command -v python3 >/dev/null 2>&1; then
    v=$(python3 --version 2>&1); v="${v#Python }"   # some builds print to stderr
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] && _RT="$v"
  fi
}

seg_node() {  # active Node version (.nvmrc/.node-version/nvm); silent when none
  [ -n "$cwd" ] || return 0
  runtime_node "$cwd"; [ -n "$_RT" ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_NODE:-$VL_BG_MODEL}" "${_FG} ${VL_NODE_GLYPH} ${_RT} "
}

seg_python() {  # active Python env (venv/conda/pyenv); silent when none detected
  [ -n "$cwd" ] || return 0
  runtime_python "$cwd"; [ -n "$_RT" ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_PYTHON:-$VL_BG_MODEL}" "${_FG} ${VL_PY_GLYPH} ${_RT} "
}

# ── Subagent panel row segments (--subagent mode) ────────────────────────────
# Same push() convention as seg_*; input is one task's t_* globals set by the
# --subagent loop below the render helpers. Per-field degradation: a missing
# field hides its segment (ctx shrinks to a bare count); the row always renders.

sub_epoch() {  # → _EP ; strict startTime parser for the per-task loop.
  # Accepts only shapes it can resolve fork-free: pure-digit epoch seconds,
  # pure-digit epoch milliseconds (13+ digits), and canonical valid UTC ISO.
  # Anything else hides elapsed instead of reaching to_epoch's date fallback.
  local t="$1"
  case "$t" in
    ('') return 1 ;;
    (*[!0-9]*) iso_epoch "$t" ;;
    (*)
      if [ "${#t}" -ge 13 ]; then _EP=$(( 10#$t / 1000 ))
      else _EP=$(( 10#$t )); fi
      return 0 ;;
  esac
}

subagent_role() {  # → _SUB_ROLE ; $1=transcript path $2=task id
  local transcript="$1" id="$2" path line role
  _SUB_ROLE=""
  case "$id" in (''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;; esac
  case "$transcript" in (*.jsonl) path="${transcript%.jsonl}/subagents/agent-${id}.meta.json" ;; (*) return 1 ;; esac
  path="${path//\\//}"  # native Windows payload paths use backslashes; Git Bash accepts C:/...
  [ -r "$path" ] || return 1
  IFS= read -r line < "$path" || [ -n "$line" ] || return 1
  case "$line" in
    (*'"agentType":"'*) role="${line#*\"agentType\":\"}" ; role="${role%%\"*}" ;;
    (*) return 1 ;;
  esac
  case "$role" in (''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;; esac
  _SUB_ROLE="$role"
}

subseg_name() {  # identity + task label; each falls back independently
  local identity="${t_name:-${t_role:-}}" detail="${t_label:-${t_desc:-}}" label col
  if [ -n "${t_name:-}" ] && [ -n "${t_role:-}" ] && [ "$t_name" != "$t_role" ]; then
    identity="$t_name ($t_role)"
  fi
  if [ -n "$identity" ]; then
    label="$identity"
    [ -n "$detail" ] && [ "$detail" != "${t_name:-}" ] && [ "$detail" != "${t_role:-}" ] && label="$label · $detail"
  else
    label="${detail:-$t_type}"
  fi
  [ -n "$label" ] || return 0
  case "$t_status" in
    (running|in_progress|active) col="$VL_FG_TEXT" ;;
    (completed|success|done)     col="$VL_FG_OK"   ;;
    (failed|error|cancelled)     col="$VL_FG_HOT"  ;;
    (*)                          col="$VL_FG_DIM"  ;;  # incl. missing → unknown
  esac
  fg "$col"; trunc "$label" "$VL_NAME_MAX"
  push "${VL_BG_SUB_NAME:-$VL_BG_DIR}" "${BOLD}${_FG} ${_TR} ${NORM}"
}

subseg_model() {  # per-task resolved model, short-named; hidden when unresolved
  [ -n "$t_model" ] || return 0
  model_short "$t_model"
  fg "$VL_FG_TEXT"
  push "${VL_BG_SUB_MODEL:-$VL_BG_MODEL}" "${BOLD}${_FG} ◆ ${_MS} ${NORM}"
}

subseg_ctx() {  # per-task context gauge; bare token count without a window size
  local tokint="${t_tok%%.*}" cws="$t_cws" ci fgc fgd
  case "$tokint" in (''|*[!0-9]*) return 0 ;; esac
  # ponytail: 16 digits keeps *100 inside signed 64-bit Bash arithmetic; use
  # non-overflow ratio math before widening this display-only ceiling.
  [ "${#tokint}" -le 16 ] || return 0
  tokint=$(( 10#$tokint ))
  fmt_tok "$tokint"
  case "$cws" in (''|*[!0-9]*) cws=0 ;; esac
  if [ "${#cws}" -le 16 ]; then cws=$(( 10#$cws )); else cws=0; fi
  if [ "$cws" -gt 0 ]; then
    ci=$(( (tokint * 100) / cws )); [ "$ci" -gt 100 ] && ci=100
    make_bar "$ci"; pct_fg "$ci"
    fg "$_PFG";      fgc="$_FG"
    fg "$VL_FG_DIM"; fgd="$_FG"
    push "${VL_BG_SUB_CTX:-$VL_BG_CTX}" "${fgc} ${VL_CTX_GLYPH} ${_BAR} ${ci}% ${fgd}${_TOK} "
  else
    fg "$VL_FG_DIM"
    push "${VL_BG_SUB_CTX:-$VL_BG_CTX}" "${_FG} ${VL_CTX_GLYPH} ${_TOK} "
  fi
}

subseg_elapsed() {  # wall-clock since startTime; hidden when unparseable
  [ -n "$t_start" ] || return 0
  sub_epoch "$t_start" || return 0
  local diff=$(( NOW - _EP ))
  [ "$diff" -ge 0 ] || return 0
  fmt_duration $(( diff * 1000 )) 1
  fg "$VL_FG_TEXT"
  push "${VL_BG_SUB_ELAPSED:-$VL_BG_DURATION}" "${_FG} ⧖ ${_DUR} "
}

# ── Render ───────────────────────────────────────────────────────────────────
build_segments() {
  local s
  SEG_BGS=() ; SEG_TXT=() ; SEG_LEN=()
  for s in $1; do
    command -v "seg_$s" >/dev/null 2>&1 && "seg_$s"
  done
}

render_range() {  # → _ROW ; assemble segments $1..$2 (inclusive) as one row
  local i out lbg=""
  if [ "$VL_STYLE" = "lean" ]; then
    # VL_LEAN_BG paints one uniform background behind the row; re-assert it after
    # every reset so the bar stays continuous across separators (p10k "classic").
    [ -n "${VL_LEAN_BG:-}" ] && { bg "$VL_LEAN_BG"; lbg="$_BG"; }
    out=""
    # VL_LEAN_CAP_L bevels the bar's start into the terminal — the mirror of
    # VL_LEAN_CAP_R — drawn in the bar colour on the default background.
    if [ -n "$lbg" ] && [ -n "${VL_LEAN_CAP_L:-}" ]; then
      fg "$VL_LEAN_BG"; out="${R}${_FG}${VL_LEAN_CAP_L}"
    fi
    for ((i=$1; i<=$2; i++)); do
      fg "${SEG_BGS[$i]}"
      out+="${R}${lbg}${_FG}${SEG_TXT[$i]}"
      [ "$i" -lt "$2" ] && out+="${R}${lbg}${VL_LEAN_SEP}"
    done
    # VL_LEAN_CAP_R bevels the bar's end into the terminal (p10k's trailing segment
    # separator): the cap glyph is drawn in the bar colour on the default background.
    if [ -n "$lbg" ] && [ -n "${VL_LEAN_CAP_R:-}" ]; then
      fg "$VL_LEAN_BG"; out+="${R}${_FG}${VL_LEAN_CAP_R}"
    fi
    _ROW="${out}${R}"
    return 0
  fi
  fg "${SEG_BGS[$1]}"
  out="${R}${_FG}${VL_CAP_L}"
  for ((i=$1; i<=$2; i++)); do
    bg "${SEG_BGS[$i]}"
    out+="${_BG}${SEG_TXT[$i]}"
    if [ "$i" -lt "$2" ]; then
      bg "${SEG_BGS[$((i+1))]}"; fg "${SEG_BGS[$i]}"
      out+="${_BG}${_FG}${VL_SEP}"
    fi
  done
  fg "${SEG_BGS[$2]}"
  out+="${R}${_FG}${VL_CAP_R}${R}"
  _ROW="$out"
}

print_range() {  # render segments $1..$2 (inclusive) as one row
  render_range "$1" "$2"
  printf '%s\n' "$_ROW"
}

# Terminal width for auto layout; 0 = unknown (then stay on one line).
term_cols() {  # → _COLS
  local c=""
  if [ -n "$COLUMNS" ]; then
    c="$COLUMNS"
  else
    c=$(stty size 2>/dev/null </dev/tty) && c="${c#* }" || c=""
  fi
  case "$c" in (''|*[!0-9]*) c=0 ;; esac
  _COLS="$c"
}

# ── Subagent panel mode ──────────────────────────────────────────────────────
# stdin: {columns, tasks:[…]} (Claude Code subagentStatusLine, v2.1.205+ for
# model/contextWindowSize). stdout: one {"id","content"} line per row. Reuses
# the theme and render_range, so panel rows match the main bar. jq failure or
# an empty tasks list prints nothing → Claude Code keeps its default rows.
# Placement matters: this branch exits before every main-bar-only side effect
# below (git probe, burn/limit sampling, float readout — and the main JSON
# parse), so none of them needs a mode guard.
if [ "$SUBAGENT_MODE" = "1" ]; then
  # Panel rows are single independent rows: SEG_LEN[] (auto-layout wrap input)
  # is never read, so force non-auto layout — push() then skips its
  # per-character width scan for every panel segment.
  VL_LAYOUT=fixed
  # scrub drops C0, DEL, and C1 control characters from every extracted field
  # BEFORE the stream below is framed with newlines and unit separators.
  # That one pass is both the security scrub — a crafted label could otherwise
  # smuggle terminal escapes (ESC[2J confirmed live) into the rendered row —
  # and the framing guard: a literal newline or 0x1f inside a field would
  # otherwise split it into extra lines/fields, letting a task forge a whole
  # {"id",...} row or shift every field after it. json_escape below therefore
  # only ever sees coralline's own ANSI codes.
  #
  # Claude Code can deliver several concatenated {columns,tasks} documents in
  # one read (no newlines between them; captured live). Each is a full panel
  # snapshot, so only the newest is current: slurp the stream (-s) and render
  # just the last document — otherwise stale rows (and duplicate ids) would
  # precede the fresh ones.
  SUB_LINES=$(printf '%s' "$input" | jq -rs '
    def scrub: tostring | gsub("[\\x00-\\x1f\\x7f\u0080-\u009f]"; "");
    (last // {}) as $d |
    ($d.tasks[]? | [
      "task",
      ($d.transcript_path // ""),
      (.id // ""),
      (.name // ""),
      (.label // ""),
      (.description // ""),
      (.type // ""),
      (.status // ""),
      (.startTime // ""),
      (.model // ""),
      (.contextWindowSize // ""),
      (.tokenCount // "")
    ] | map(scrub) | join("\u001f"))' 2>/dev/null)
  while IFS=$'\037' read -r sub_kind t_transcript t_id t_name t_label t_desc t_type t_status t_start t_model t_cws t_tok; do
    [ "$sub_kind" = "task" ] || continue
    t_tok="${t_tok%$'\r'}"  # native Windows jq writes CRLF; input CR was scrubbed above
    [ -n "$t_id" ] || continue
    t_role=""
    [ "$t_type" = "local_agent" ] && subagent_role "$t_transcript" "$t_id" && t_role="$_SUB_ROLE"
    SEG_BGS=() ; SEG_TXT=() ; SEG_LEN=()
    for s in $VL_SUB_SEGMENTS; do
      command -v "subseg_$s" >/dev/null 2>&1 && "subseg_$s"
    done
    [ "${#SEG_BGS[@]}" -gt 0 ] || continue
    render_range 0 $(( ${#SEG_BGS[@]} - 1 ))
    json_escape "$_ROW" ; sub_row="$_JS"
    json_escape "$t_id"
    printf '{"id":"%s","content":"%s"}\n' "$_JS" "$sub_row"
  done <<SUB
$SUB_LINES
SUB
  exit 0
fi

# ── Parse JSON (single jq call) ──────────────────────────────────────────────
# Fields are joined with \x1f (unit separator): unlike tab, a non-whitespace
# IFS preserves empty fields instead of collapsing consecutive delimiters.
IFS=$'\037' read -r cwd model ctx_pct tok_in tok_out tok_cr tok_cw \
                 fh_pct fh_rst wd_pct wd_rst cost \
                 lines_add lines_del out_style dur_ms effort <<JSON
$(printf '%s' "$input" | jq -r '
  def scrub: tostring | gsub("[\\x00-\\x1f\\x7f\u0080-\u009f]"; "");
  [
    (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""),
    (.context_window.used_percentage // "" | tostring),
    (.context_window.total_input_tokens // 0),
    (.context_window.total_output_tokens // 0),
    (.context_window.current_usage.cache_read_input_tokens // 0),
    (.context_window.current_usage.cache_creation_input_tokens // 0),
    (.rate_limits.five_hour.used_percentage // "" | tostring),
    (.rate_limits.five_hour.resets_at // "" | tostring),
    (.rate_limits.seven_day.used_percentage // "" | tostring),
    (.rate_limits.seven_day.resets_at // "" | tostring),
    (.cost.total_cost_usd // "" | tostring),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0),
    (.output_style.name // ""),
    (.cost.total_duration_ms // 0),
    (.effort.level // "")
  ] | map(scrub) | join("")' 2>/dev/null)
JSON

_SEG_SCAN=" $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 "
[ "$VL_FLOAT" = "1" ] && _SEG_SCAN="$_SEG_SCAN$VL_FLOAT_SEGMENTS "
case "$_SEG_SCAN" in *" git "*|*" stash "*|*" project "*) read_git ;; esac

# Burn and synced limits share one bounded snapshot. The disabled/default path
# never opens the controller; CORALLINE_NO_SAMPLE keeps the same reads but makes
# GC, publication, healing, and root creation impossible.
_STATE_READY=0; _STATE_BURN_GATE=0; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0
case "$_SEG_SCAN" in (*" burn "*) _STATE_BURN_GATE=1 ;; esac
if [ "$VL_LIMIT_SYNC" = 1 ]; then
  case "$_SEG_SCAN" in (*" limit5h "*) _STATE_RL5_GATE=1 ;; esac
  case "$_SEG_SCAN" in (*" limit7d "*|*" burn "*) _STATE_RL7_GATE=1 ;; esac
fi
if [ "$_STATE_BURN_GATE" = 1 ] || [ "$_STATE_RL5_GATE" = 1 ] || [ "$_STATE_RL7_GATE" = 1 ]; then
  state_prepare
fi

# Defensive ANSI stripper (the VL_NOCOLOR path should already emit none) → _PLAIN.
strip_ansi() {
  local s="$1" out=""
  while [ "${s#*$ESC}" != "$s" ]; do
    out+="${s%%$ESC*}" ; s="${s#*$ESC}" ; s="${s#*m}"
  done
  _PLAIN="$out$s"
}

# Build VL_FLOAT_SEGMENTS with color emission neutralized and write a single
# plain-text line atomically to VL_FLOAT_FILE. Saves/restores the color globals
# so the normal render that follows is unaffected.
emit_float() {
  local _nc="$VL_NOCOLOR" _b="$BOLD" _n="$NORM" _r="$R"
  local dir line i s tmp
  VL_NOCOLOR=1 ; BOLD="" ; NORM="" ; R=""
  build_segments "$VL_FLOAT_SEGMENTS"
  line=""
  for ((i=0; i<${#SEG_TXT[@]}; i++)); do
    strip_ansi "${SEG_TXT[$i]}" ; s="$_PLAIN"
    s="${s#"${s%%[![:space:]]*}"}" ; s="${s%"${s##*[![:space:]]}"}"   # trim
    [ -n "$s" ] || continue
    line="${line:+$line$VL_FLOAT_SEP}$s"
  done
  VL_NOCOLOR="$_nc" ; BOLD="$_b" ; NORM="$_n" ; R="$_r"
  dir=$(dirname "$VL_FLOAT_FILE")
  mkdir -p "$dir"
  tmp="$dir/.float.tmp.$$"
  printf '%s\n' "$line" > "$tmp" && mv -f "$tmp" "$VL_FLOAT_FILE" || rm -f "$tmp"
}

[ "$VL_FLOAT" = "1" ] && emit_float

if [ "$VL_LAYOUT" = "auto" ]; then
  build_segments "$VL_SEGMENTS"
  total=${#SEG_BGS[@]}
  [ "$total" -eq 0 ] && exit 0
  term_cols; W="$_COLS"
  if [ "$W" -le 0 ] || [ "$VL_MAX_LINES" -le 1 ]; then
    print_range 0 $((total - 1))
    exit 0
  fi
  # Reserve a right-hand margin so wrapped lines never touch the window edge.
  W=$(( W - VL_WRAP_MARGIN ))
  [ "$W" -lt 1 ] && W=1
  # Greedy wrap: per line, width = caps + segment widths + separators.
  # Once VL_MAX_LINES is reached, everything left stays on the last line.
  if [ "$VL_STYLE" = "lean" ]; then CAP_W=$(( ${#VL_LEAN_CAP_L} + ${#VL_LEAN_CAP_R} )) ; SEP_W=${#VL_LEAN_SEP}
  else                              CAP_W=2 ; SEP_W=1 ; fi
  start=0 ; line=1 ; cur=$(( CAP_W + SEG_LEN[0] ))
  for ((i=1; i<total; i++)); do
    need=$(( cur + SEP_W + SEG_LEN[i] ))
    if [ "$need" -gt "$W" ] && [ "$line" -lt "$VL_MAX_LINES" ]; then
      print_range "$start" $((i - 1))
      start=$i ; line=$((line + 1)) ; cur=$(( CAP_W + SEG_LEN[i] ))
    else
      cur=$need
    fi
  done
  print_range "$start" $((total - 1))
else
  for list in "$VL_SEGMENTS" "$VL_SEGMENTS2" "$VL_SEGMENTS3"; do
    [ -n "$list" ] || continue
    build_segments "$list"
    [ "${#SEG_BGS[@]}" -gt 0 ] && print_range 0 $(( ${#SEG_BGS[@]} - 1 ))
  done
fi
exit 0
