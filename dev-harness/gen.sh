#!/usr/bin/env bash
# gen.sh <storedir> <n_markers> <n_tsv_lines>
# Builds a synthetic coralline state store anchored to *now*, so every marker is
# "plausible" (reset in the future) and the render takes the hot path.
set -eu
store="$1"; n="$2"; tsv="$3"
now=$(date +%s)
rst=$(( now + 3600 ))
rm -rf "$store" "${store%.d}.tsv"
mkdir -p "$store"
# marker names: b_<12d reset>_<12d sample>_<pct 0dd.ddd>_<4d slot>
i=0
while [ "$i" -lt "$n" ]; do
  samp=$(( now - n + i ))
  p=$(( 10000 + i % 50000 ))
  printf -v name 'b_%012d_%012d_%03d.%03d_0000' "$rst" "$samp" $(( p / 1000 )) $(( p % 1000 ))
  : > "$store/$name"
  i=$(( i + 1 ))
done
# legacy TSV: <sample>\t<pct>\t<reset> — epochs unpadded, the strict epoch
# grammar rejects leading zeros
: > "${store%.d}.tsv"
i=0
while [ "$i" -lt "$tsv" ]; do
  printf '%d\t%d\t%d\n' $(( now - tsv + i )) $(( 10 + i % 90 )) "$rst" >> "${store%.d}.tsv"
  i=$(( i + 1 ))
done
