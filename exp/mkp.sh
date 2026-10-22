#!/bin/bash
# exp/mkp.sh <commit> <name> <patch> : that commit's web with a patch applied, into exp/builds/<name>
set -e
R=$(git rev-parse --show-toplevel); c=$1; n=$2; d=$R/exp/src-$n
rm -rf $d; mkdir -p $d
git -C $R archive $c web | tar -x -C $d --exclude=web/test
(cd $d && patch -p1 < $R/$3)
ln -s $R/web/node_modules $d/web/node_modules
(cd $d/web && node build.mjs >/dev/null)
mkdir -p $R/exp/builds; rm -rf $R/exp/builds/$n; mv $d/web/build/Web $R/exp/builds/$n; rm -rf $d
