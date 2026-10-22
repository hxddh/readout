#!/bin/bash
# exp/run.sh : the theme switch in code-heavy pages: 3.8.0, 207cdc5 and two variants of it (CI experiment)
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
for c in 59acabc 207cdc5; do ../exp/mk.sh $c || echo "build failed $c"; done
../exp/mkv.sh 207cdc5 nonear "s/rootMargin: '200% 0px'/rootMargin: '0px'/" || echo "variant failed"
../exp/mkv.sh 207cdc5 noblocks "s/x/x/" "s/if (all || c.classList.contains('near')) for (const el of c.children)/if (all) for (const el of c.children)/" || echo "variant failed"
grep -c "rootMargin" ../exp/builds/nonear/reader.js || true
git show 207cdc5:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2; do for c in 59acabc 207cdc5 nonear noblocks; do
  node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
done; done
