#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
FN=$(date +%s)
python3 cases.py $FN >/dev/null
./mkinput.sh > input.json
mkdir -p limit-5h.d limit-7d.d
pass=0; fail=0
printf "%-14s %-6s %9s %9s %8s\n" CASE RESULT "main(ms)" "patch(ms)" "speedup"
for c in $(ls cases); do
  d="$PWD/cases/$c"
  ec=(CORALLINE_FAKE_NOW=$FN CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$PWD/test.conf"
      CORALLINE_BURN_FILE="$d/burn.tsv" CORALLINE_RL5H_FILE="$PWD/limit-5h.tsv" CORALLINE_RL7D_FILE="$PWD/limit-7d.tsv")
  # median of 3 each
  rcf="$d/rc"; : > "$rcf"
  tn=$(for i in 1 2 3; do s=$(date +%s%N); env "${ec[@]}" bash t_repo_base.sh < input.json > "$d/out.new" 2>/dev/null; echo $? >> "$rcf"; e=$(date +%s%N); echo $(( (e-s)/1000000 )); done | sort -n | sed -n 2p)
  tf=$(for i in 1 2 3; do s=$(date +%s%N); env "${ec[@]}" bash t_repo_fast.sh < input.json > "$d/out.fast" 2>/dev/null; echo $? >> "$rcf"; e=$(date +%s%N); echo $(( (e-s)/1000000 )); done | sort -n | sed -n 2p)
  bad=""
  grep -qv '^0$' "$rcf" && bad=1
  [ -s "$d/out.new" ] || bad=1
  [ -s "$d/out.fast" ] || bad=1
  if [ -n "$bad" ]; then r=RC; fail=$((fail+1))
  elif cmp -s "$d/out.new" "$d/out.fast"; then r=OK; pass=$((pass+1))
  else r=DIFF; fail=$((fail+1)); fi
  printf '%-14s %-6s %9s %9s %7sx\n' "$c" "$r" "$tn" "$tf" "$(awk -v a=$tn -v b=$tf 'BEGIN{printf "%.1f", (b>0?a/b:0)}')"
done
echo; echo "pass=$pass fail=$fail"
