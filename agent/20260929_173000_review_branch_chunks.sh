#!/usr/bin/env bash
# CodeRabbit over the simplify branch diff since the last reviewed commit, one directory at a time (the whole diff is
# "payload_too_large"). Usage: bash agent/20260929_173000_review_branch_chunks.sh <base commit> <tag> <dir>...
# Logs: agent/20260929_173000_coderabbit_<tag>_<dir with / -> _>.txt; prints the findings count per chunk.
cd /Users/fvrodriguez/repos/zealgt-simplify || exit 1
BASE="$1"; TAG="$2"; shift 2
for d in "$@"; do
    log="agent/20260929_173000_coderabbit_${TAG}_$(printf '%s' "$d" | tr '/.' '__').txt"
    coderabbit review --committed --base-commit "$BASE" --dir "$d" --agent > "$log" 2>&1
    st=$?
    res=$(grep -o '"type":"complete"[^,]*,"status":"[^"]*","findings":[0-9]*' "$log" | tail -1)
    err=$(grep -o '"type":"error"[^}]*' "$log" | head -1 | cut -c1-200)
    echo "$d exit=$st ${res:-no-complete} ${err}"
done
