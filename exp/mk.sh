#!/bin/bash
# exp/mk.sh <commit> : builds that commit's web into exp/builds/<commit>
set -e
R=$(git rev-parse --show-toplevel); c=$1; d=$R/exp/src-$c
rm -rf $d; mkdir -p $d
git -C $R archive $c web | tar -x -C $d --exclude=web/test
ln -s $R/web/node_modules $d/web/node_modules
(cd $d/web && node build.mjs >/dev/null)
mkdir -p $R/exp/builds; rm -rf $R/exp/builds/$c; mv $d/web/build/Web $R/exp/builds/$c; rm -rf $d
