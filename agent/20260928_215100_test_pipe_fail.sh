#!/usr/bin/env bash
# Checks the zg_pipe_fail idiom of ALIGN_MARKDUP / MARKDUP_IMPORT under the task shell options (-e -u -o pipefail).
# Exits non-zero if any case gives the wrong status.
set -euo pipefail
zg_pipe_fail() {
    local s sig=0 first=0
    for s in "$@"; do
        if [ "$s" -eq 137 ]; then
            sig=137
        elif [ "$s" -gt 128 ] && [ "$sig" -eq 0 ]; then
            sig=$s
        fi
        [ "$first" -ne 0 ] || first=$s
    done
    echo "pipe statuses $*" >&2
    [ "$sig" -eq 0 ] || exit "$sig"
    exit $(( first ? first : 1 ))
}
fail=0
check() { echo "case $1 -> $2 (want $3)"; [ "$2" = "$3" ] || fail=1; }
( cat /dev/null | sh -c 'kill -9 $$' | sh -c 'exit 1' || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; check OOM-like "$rc" 137
( sh -c 'kill -PIPE $$' | sh -c 'kill -9 $$' | sh -c 'exit 1' || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; check SIGPIPE-then-OOM "$rc" 137
( true | sh -c 'exit 3' | sh -c 'exit 1' || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; check plain "$rc" 3
( true | true || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; check ok "$rc" 0
exit "$fail"
