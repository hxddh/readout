#!/bin/bash
# exp/run.sh : the scroll measurements for every 3.9 commit (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc fc48b78 e6db579 5c445ef 4c6d79a 794868d 63adca0 e9b7415 f742c5e 54e4e32 a6b1e32}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
mkdir -p ../exp/out
for spec in ${SPECS:-500000:0 500000:1 1000000:0 5000000:0}; do
  size=${spec%:*}; marks=${spec#*:}
  for rep in 1 2; do
    for c in $COMMITS; do
      node ../exp/scroll.mjs ../exp/builds/$c $size $marks 1 >> ../exp/out/scroll.jsonl || echo "run failed $c $spec"
    done
  done
done
