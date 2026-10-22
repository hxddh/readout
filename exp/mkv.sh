#!/bin/bash
# exp/mkv.sh <commit> <name> <sed script for chunks.js> [<sed script for anchor.js>] : a variant build into exp/builds/<name>
set -e
R=$(git rev-parse --show-toplevel); c=$1; n=$2; d=$R/exp/src-$n
rm -rf $d; mkdir -p $d
git -C $R archive $c web | tar -x -C $d --exclude=web/test
sed -i "$3" $d/web/src/reader/chunks.js
[ -n "$4" ] && sed -i "$4" $d/web/src/reader/anchor.js
ln -s $R/web/node_modules $d/web/node_modules
(cd $d/web && node build.mjs >/dev/null)
mkdir -p $R/exp/builds; rm -rf $R/exp/builds/$n; mv $d/web/build/Web $R/exp/builds/$n; rm -rf $d
