#!/bin/sh
# Instructions the update path of perf-probe executes, counted by valgrind:
# the whole process loading a document and running one update, minus the
# same process only loading it (parsing runs on several threads, so the
# whole process is counted). Independent of the machine's speed and load,
# so CI can gate it tightly (tools/perf-budgets.json, update_1mb_instructions).
#
# usage: Packages/ReadoutCore/Tools/perf-instructions.sh PERF_PROBE CORPUS_DIR BYTES
#   build PERF_PROBE with: swift build -c release --package-path Packages/ReadoutCore --product perf-probe
set -eu
count() {
    valgrind --tool=callgrind --callgrind-out-file=/dev/null "$@" 2>&1 \
        | sed -n 's/.*Collected : \([0-9][0-9]*\).*/\1/p'
}
total=$(count "$1" "$2" "$3")
load=$(count "$1" "$2" "$3" load)
if [ -z "$total" ] || [ -z "$load" ]; then
    echo "perf-instructions: no count from valgrind" >&2
    exit 1
fi
echo $((total - load))
