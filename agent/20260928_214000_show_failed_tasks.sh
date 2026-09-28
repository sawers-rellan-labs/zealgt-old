#!/bin/bash
# Show the failed tasks of a run (read-only): work dir, .command.err tail, .command.sh.  usage: bash -s <run_id>  (stdin script)
run=${1:-gate1_import}
L=/share/maize/frodrig4/nf_work/$run/launch/.nextflow.log
for d in $(grep -oE "workDir: [^ ;]+|Work dir:" "$L" >/dev/null; grep -A1 "^Work dir:" "$L" | grep -v "Work dir" | grep -oE "/share/[^ ]+" | sort -u); do
    echo "=========== $d"
    echo "--- .command.sh"; cat "$d/.command.sh"
    echo "--- .command.err (tail 40)"; tail -n 40 "$d/.command.err"
    echo "--- .exitcode: $(cat $d/.exitcode 2>/dev/null)"
done
