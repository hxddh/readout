#!/bin/bash
# exp/run.sh : perf.test (of FIX) against the builds of COMMITS, twice each (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-1f67d91 207cdc5}"
FIX="${FIX:-207cdc5}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
git show $FIX:web/test/perf.test.mjs > test/perf.test.mjs
mkdir -p ../exp/out
for rep in 1 2; do for c in $COMMITS; do
  rm -rf build/Web; mkdir -p build; cp -r ../exp/builds/$c build/Web
  node test/perf.test.mjs > ../exp/out/perf-$c-$rep.log 2>&1 || echo "perf failed $c"
  cp test/out/perf-web.json ../exp/out/perf-$c-$rep.json || true
done; done
