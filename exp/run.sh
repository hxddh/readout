#!/bin/bash
# exp/run.sh : code-heavy shapes, 3.8.0 against the fix, with the page's element count (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc cfd92e6}"
FIX="${FIX:-cfd92e6}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2 3; do for c in $COMMITS; do
  HUGE=1 node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
done; done
