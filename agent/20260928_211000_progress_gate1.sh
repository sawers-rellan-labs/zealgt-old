#!/bin/bash
# Gate 1 progress (read-only): head job states, last head-log lines, errors in .nextflow.log.
W=/share/maize/frodrig4/nf_work
squeue -u frodrig4 -o "%.10i %.20j %.8T %.10M %.6C %.8m %R" | head -n 40
for run in gate1_1A gate1_import; do
    L=$W/$run/launch/.nextflow.log
    [ -f "$L" ] || continue
    echo "===== $run"
    grep -E "Session UUID" "$L" | head -n 1
    grep -E "Submitted process|Cached process" "$L" | wc -l
    grep -E "ERROR|Error executing|exit status|Workflow completed|terminated" "$L" | grep -v pf4j | tail -n 8
done
for j in "$@"; do tail -n 8 $W/zealgt_head_$j.log; done
