#!/bin/bash
# exp/run.sh : perf.test of FIX with its 5 MB scroll's slow frames logged (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-207cdc5}"
FIX="${FIX:-207cdc5}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
git show $FIX:web/test/perf.test.mjs > test/perf.test.mjs
python3 ../exp/patch.py
mkdir -p ../exp/out
for rep in 1 2; do for c in $COMMITS; do
  rm -rf build/Web; mkdir -p build; cp -r ../exp/builds/$c build/Web
  node test/perf.test.mjs > ../exp/out/perf-$c-$rep.log 2>&1 || echo "perf failed $c"
  grep SLOW ../exp/out/perf-$c-$rep.log >> ../exp/out/slow.txt
done; done
