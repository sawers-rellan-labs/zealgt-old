#!/bin/bash
# Laptop-side wait: poll sacct on hazel every 60 s until none of the given jobs is PENDING/RUNNING (max ~110 min).
# usage: bash agent/20260928_210000_wait_jobs.sh <jobid,jobid,...> [max_min]
ids="$1"; max="${2:-110}"
for i in $(seq 1 "$max"); do
    s=$(ssh hazel "sacct -j $ids -X -n --format=JobID,State,Elapsed" 2>/dev/null || true)
    if [ -n "$s" ] && ! echo "$s" | grep -qE 'PENDING|RUNNING|REQUEUED|CONFIGURING'; then
        echo "$s"; exit 0
    fi
    sleep 60
done
echo "timeout; last:"; echo "$s"
