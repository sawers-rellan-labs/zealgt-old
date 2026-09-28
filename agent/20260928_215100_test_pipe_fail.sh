#!/usr/bin/env bash
# Checks the zg_pipe_fail idiom of ALIGN_MARKDUP / MARKDUP_IMPORT under the task shell options (-e -u -o pipefail).
set -euo pipefail
zg_pipe_fail() {
    local s first=0
    for s in "$@"; do
        if [ "$s" -gt 128 ]; then echo "pipe statuses $*; exiting $s" >&2; exit "$s"; fi
        [ "$first" -ne 0 ] || first=$s
    done
    echo "pipe statuses $*" >&2
    exit $(( first ? first : 1 ))
}
( cat /dev/null | sh -c 'kill -9 $$' | sh -c 'exit 1' || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; echo "case OOM-like -> $rc (want 137)"
( true | sh -c 'exit 3' | sh -c 'exit 1' || zg_pipe_fail "${PIPESTATUS[@]}" ) && rc=0 || rc=$?; echo "case plain -> $rc (want 3)"
( true | true || zg_pipe_fail "${PIPESTATUS[@]}"; echo reached ) && rc=0 || rc=$?; echo "case ok -> $rc (want 0, 'reached')"
