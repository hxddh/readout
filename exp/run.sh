#!/bin/bash
# exp/run.sh : 3.8.0 against the fix, interleaved, five runs each (CI experiment)
#   SPECS=scroll: the 500 KB / 1 MB / 5 MB scroll passes;  SPECS=code: the code-heavy shapes
set -x
R=$(git rev-parse --show-toplevel); cd $R/web
COMMITS="${COMMITS:-59acabc 59add16}"
FIX="${FIX:-59add16}"
for c in $COMMITS; do if [ "$c" = wip ]; then ../exp/mkp.sh $FIX wip exp/wip.patch || echo "build failed wip"; else ../exp/mk.sh $c || echo "build failed $c"; fi; done
git show $FIX:web/test/scrollperf.mjs > test/scrollperf.mjs
mkdir -p ../exp/out
ln -sfn ../web/node_modules ../exp/node_modules
for rep in 1 2 3 4 5; do for c in $COMMITS; do
  if [ "$SPECS" = huge ] && [ $rep -le 3 ]; then
    HUGE=1 node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
  elif [ "$SPECS" = huge ]; then
    true
  elif [ "$SPECS" = code ]; then
    node ../exp/code.mjs ../exp/builds/$c >> ../exp/out/code.jsonl 2>>../exp/out/code-err.log || echo "run failed $c"
  else
    SCROLL_ONLY=1 node ../exp/baseline.mjs ../exp/builds/$c >> ../exp/out/scroll.jsonl 2>>../exp/out/scroll-err.log || echo "run failed $c"
  fi
done; done
