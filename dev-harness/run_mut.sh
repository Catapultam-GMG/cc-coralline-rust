#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
FN=$(date +%s); python3 cases.py $FN >/dev/null; ./mkinput.sh > input.json
rm -rf mut; mkdir -p mut
pass=0; fail=0
for c in $(ls cases); do
  bad=""
  for v in base fast; do
    cp -a "cases/$c" "mut/$c.$v"
    env CORALLINE_FAKE_NOW=$FN CORALLINE_CONFIG="$PWD/test.conf" \
        CORALLINE_BURN_FILE="$PWD/mut/$c.$v/burn.tsv" \
        CORALLINE_RL5H_FILE="$PWD/mut/l5.$c.$v.tsv" CORALLINE_RL7D_FILE="$PWD/mut/l7.$c.$v.tsv" \
        bash t_repo_$v.sh < input.json > "mut/$c.$v.out" 2>/dev/null || bad=1
    [ -s "mut/$c.$v.out" ] || bad=1
    ( cd "mut/$c.$v/burn.d" && LC_ALL=C find . | LC_ALL=C sort ) > "mut/$c.$v.ls"
    ( cd mut && LC_ALL=C find "l5.$c.$v.d" "l7.$c.$v.d" 2>/dev/null | sed "s/$c\.$v//" | LC_ALL=C sort ) > "mut/$c.$v.lim"
  done
  o=$(cmp -s "mut/$c.base.out" "mut/$c.fast.out" && echo . || echo OUT)
  s=$(cmp -s "mut/$c.base.ls"  "mut/$c.fast.ls"  && echo . || echo STORE)
  l=$(cmp -s "mut/$c.base.lim" "mut/$c.fast.lim" && echo . || echo LIMIT)
  if [ -n "$bad" ]; then r=RC; fail=$((fail+1))
  elif [ "$o$s$l" = "..." ]; then r=OK; pass=$((pass+1))
  else r=DIFF; fail=$((fail+1)); fi
  printf '%-14s %-6s %s files:%s/%s\n' "$c" "$r" "$o$s$l" "$(wc -l < "mut/$c.base.ls")" "$(wc -l < "mut/$c.fast.ls")"
done
echo; echo "mutation pass=$pass fail=$fail"
