#!/bin/bash
# exp/run.sh : the scroll measurements for every 3.9 commit (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc fc48b78 e6db579 5c445ef 4c6d79a 794868d 63adca0 e9b7415 f742c5e 54e4e32 a6b1e32}"
for c in $COMMITS; do ../exp/mk.sh $c || echo "build failed $c"; done
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for c in 59acabc a6b1e32; do for s in 500000 5000000; do for v in base noRO noIO noRO,noIO noCV; do echo "{\"frame\":\"$c $s $v\",\"r\":$(V=$v timeout 900 node ../exp/frame.mjs ../exp/builds/$c $s)}" >> ../exp/out/frame.jsonl; done; done; done
for spec in ${SPECS:-500000:0 500000:1 1000000:0 5000000:0}; do
  size=${spec%:*}; marks=${spec#*:}
  for rep in 1 2; do
    for c in $COMMITS; do
      node ../exp/scroll.mjs ../exp/builds/$c $size $marks 1 >> ../exp/out/scroll.jsonl || echo "run failed $c $spec"
    done
  done
done
