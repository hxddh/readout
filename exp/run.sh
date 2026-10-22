#!/bin/bash
# exp/run.sh : code-heavy scroll's long frames attributed, 3.8.0 and cfd92e6 (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
for c in 59acabc cfd92e6; do ../exp/mk.sh $c || echo "build failed $c"; done
git show cfd92e6:web/test/scrollperf.mjs > test/scrollperf.mjs
git show cfd92e6:web/test/perf.test.mjs > test/perf.test.mjs
python3 ../exp/patch2.py
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2; do for c in 59acabc cfd92e6; do
  node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
done; done
