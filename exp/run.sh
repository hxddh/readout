#!/bin/bash
# exp/run.sh : perf.test of 59add16 three times, each 5 MB scroll frame over 50 ms attributed (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
../exp/mk.sh 59add16 || echo "build failed"
git show 59add16:web/test/scrollperf.mjs > test/scrollperf.mjs
git show 59add16:web/test/perf.test.mjs > test/perf.test.mjs
python3 ../exp/patch2.py
mkdir -p ../exp/out
for rep in 1 2 3; do
  rm -rf build/Web; mkdir -p build; cp -r ../exp/builds/59add16 build/Web
  node test/perf.test.mjs > ../exp/out/perf-$rep.log 2>&1 || echo "perf failed"
  grep '^SLOW' ../exp/out/perf-$rep.log >> ../exp/out/slow.txt
done
