#!/bin/bash
# exp/run.sh : code-heavy scroll's long frames: 3.8.0, cfd92e6 and chunks capped lower (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
for c in 59acabc cfd92e6; do ../exp/mk.sh $c || echo "build failed $c"; done
../exp/mkv.sh cfd92e6 span2500 "s/^const SPAN = 4000;/const SPAN = 2500;/" || echo "variant failed"
../exp/mkv.sh cfd92e6 span6000 "s/^const SPAN = 4000;/const SPAN = 6000;/" || echo "variant failed"
git show cfd92e6:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2 3; do for c in 59acabc cfd92e6 span2500 span6000; do
  node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
done; done
