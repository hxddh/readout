#!/bin/bash
# exp/run.sh : the 5 MB scroll passes' slow frames, before and after 96c63d1 (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-1f67d91 5d7487c}"
FIX="${FIX:-5d7487c}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for c in $COMMITS; do
  node ../exp/frames.mjs ../exp/builds/$c >> ../exp/out/frames.jsonl 2>>../exp/out/frames-err.log || echo "run failed $c"
done
