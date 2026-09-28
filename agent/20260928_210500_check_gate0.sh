#!/bin/bash
# Gate 0 post-run check on hazel (read-only): run status, task counts, storeDir files, registry, "Creating env".
R=/rsstu/users/r/rrellan/BZea/ZEAL/results/zealgt
W=/share/maize/frodrig4/nf_work
for run in gate0_demux gate0_import; do
    echo "===== $run"
    L=$W/$run/launch/.nextflow.log
    grep -E "Session UUID|Execution complete|Workflow completed|ERROR|exit status" "$L" | head -n 20
    echo "-- Creating env lines: $(grep -c 'Creating env' "$L")"
    echo "-- tasks (Submitted process lines): $(grep -c 'Submitted process' $W/$run/launch/.nextflow.log)"
    echo "-- store files:"
    find $R/$run/store_stub -type f 2>/dev/null | sort
    echo "-- registry:"
    for f in $R/$run/store_stub/registry/*; do [ -f "$f" ] && { echo "$f"; cat "$f"; }; done
    echo "-- outdir top:"
    ls $R/$run
    echo "-- work size / files:"
    du -sh $W/$run/work 2>/dev/null
    find $W/$run/work -type f 2>/dev/null | wc -l
done
