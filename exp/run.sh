#!/bin/bash
# exp/run.sh : perf.test's 5 MB sequence before its scroll, the slow frames logged (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-1f67d91 207cdc5}"
FIX="${FIX:-207cdc5}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for steps in edit,jump,find,marks marks find jump edit; do for c in $COMMITS; do
  STEPS=$steps REPS=2 node ../exp/p5.mjs ../exp/builds/$c >> ../exp/out/p5.jsonl 2>>../exp/out/p5-err.log || echo "run failed $c"
done; done
