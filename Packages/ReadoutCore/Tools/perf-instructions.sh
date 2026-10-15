#!/bin/sh
# Instructions a step of perf-probe executes, counted by valgrind: the whole
# process running up to and including the step, minus the same process
# stopping before it (parsing runs on several threads, so the whole process
# is counted). Independent of the machine's speed and load, so CI can gate
# it tightly (tools/perf-budgets.json, *_minstr).
#
# usage: Packages/ReadoutCore/Tools/perf-instructions.sh PERF_PROBE CORPUS_DIR BYTES [SCENARIO]
#   SCENARIO: update (default), append or open-unique (see perf-probe)
#   build PERF_PROBE with: swift build -c release --package-path Packages/ReadoutCore --product perf-probe
set -eu
scenario=${4:-update}
count() {
    valgrind --tool=callgrind --callgrind-out-file=/dev/null "$@" 2>&1 \
        | sed -n 's/.*Collected : \([0-9][0-9]*\).*/\1/p'
}
total=$(count "$1" "$2" "$3" 0 "$scenario")
load=$(count "$1" "$2" "$3" load "$scenario")
if [ -z "$total" ] || [ -z "$load" ]; then
    echo "perf-instructions: no count from valgrind" >&2
    exit 1
fi
echo $((total - load))
