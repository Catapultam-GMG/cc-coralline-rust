#!/usr/bin/env bash
# bench.sh <script> <storedir> <reps>
# Prints median wall-clock ms over <reps> renders. Regenerates nothing: caller sets up state.
set -eu
script="$1"; store="$2"; reps="${3:-5}"
export CORALLINE_BURN_FILE="${store%.d}.tsv"
export CORALLINE_RL5H_FILE="$PWD/limit-5h.tsv"
export CORALLINE_RL7D_FILE="$PWD/limit-7d.tsv"
times=()
for _ in $(seq 1 "$reps"); do
  s=$(date +%s%N)
  bash "$script" < input.json > /dev/null 2>&1 || true
  e=$(date +%s%N)
  times+=( $(( (e - s) / 1000000 )) )
done
printf '%s\n' "${times[@]}" | sort -n | awk -v n="${#times[@]}" 'NR==int((n+1)/2){print $1}'
