#!/bin/bash
# exp/run.sh : perf.test's scroll and interaction measures for 3.8.0, 3.9.0 and the fix (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc a6b1e32 ef62f12}"
FIX="${FIX:-ef62f12}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2; do for c in $COMMITS; do
  node ../exp/baseline.mjs ../exp/builds/$c >> ../exp/out/baseline.jsonl || echo "run failed $c"
done; done
