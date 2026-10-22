#!/bin/bash
# exp/run.sh : a flowchart appended at the end of a 0 / 1 / 5 MB page, per build (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc eecc965 eb29e8e 207cdc5}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2; do for c in $COMMITS; do
  SIZES=0,1000000,5000000 node ../exp/mmd.mjs ../exp/builds/$c >> ../exp/out/mmd.txt 2>>../exp/out/mmd-err.log || echo "run failed $c"
done; done
