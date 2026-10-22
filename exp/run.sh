#!/bin/bash
# exp/run.sh : perf.test's code-heavy shapes for 3.8.0, 3.9.0 and the fix (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc a6b1e32 96c63d1}"
FIX="${FIX:-96c63d1}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for c in $COMMITS; do
  node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
done
