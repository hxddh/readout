#!/bin/sh
# Instructions a step of perf-probe executes, counted by valgrind: the whole
# process running up to and including the step, minus the same process
# stopping before it (parsing runs on several threads, so the whole process
# is counted). Independent of the machine's speed and load, so CI can gate
# it tightly (tools/perf-budgets.json, *_minstr).
#
# append, tail and mid are small steps on one thread (a splice parses one or two
# fragments, fewer than parseFragments spreads over threads): the difference
# of two processes moves by about +-5 Minstr with the load's threads, a third
# of such a step, so only the step itself is counted there (callgrind
# --toggle-collect on perf-probe's measuredUpdate), which repeats exactly.
# The difference is still taken: a step that ran on other threads too would
# be undercounted, and fails instead.
#
# usage: Packages/ReadoutCore/Tools/perf-instructions.sh PERF_PROBE CORPUS_DIR BYTES [SCENARIO]
#   SCENARIO: update (default), append, tail, mid or open-unique (see perf-probe)
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
case "$scenario" in
    append|tail|mid)
        step=$(count --toggle-collect='*measuredUpdate*' "$1" "$2" "$3" 0 "$scenario")
        if [ -z "$step" ]; then
            echo "perf-instructions: no count from valgrind" >&2
            exit 1
        fi
        # The difference may exceed the step by the noise, not by other threads' work.
        if [ $((total - load)) -gt $((step * 3 / 2 + 15000000)) ]; then
            echo "perf-instructions: $scenario step $step, process difference $((total - load)): the step ran on other threads too" >&2
            exit 1
        fi
        echo "$step"
        ;;
    *)
        echo $((total - load))
        ;;
esac
