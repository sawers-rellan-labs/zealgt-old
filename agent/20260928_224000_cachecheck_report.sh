#!/bin/bash
# Cache check A/C/D report (read-only, hazel login node: greps and md5 of small files only).
# Logs after baseline, A (no-op: all CRAMs stored), A2 (fresh store) and C (fresh store):
#   .nextflow.log.3 = baseline, .2 = A no-op, .1 = A2, .nextflow.log = C.
# -dump-hashes json tags each dump with the task index "(n)", not the sample, so the FASTQC (S_1A_1) dump is found by the
# hash prefix of its "Cached/Submitted process > ... FASTQC (S_1A_1)" line.
L=/share/maize/frodrig4/nf_work/cachecheck_fastqc/launch
W=/share/maize/frodrig4/nf_work/cachecheck_fastqc/work
O=/share/maize/frodrig4/nf_work/cachecheck_fastqc/hashdumps
mkdir -p "$O"
for name in baseline:.nextflow.log.3 A_noop:.nextflow.log.2 A2:.nextflow.log.1 C:.nextflow.log; do
    tag=${name%%:*}; f=$L/${name#*:}
    [ -f "$f" ] || continue
    echo "=================== $tag  ($f)"
    grep -m1 -E "Session UUID" "$f" | cut -c1-120
    echo "FASTQC cached: $(grep -c 'Cached process > .*FASTQC' "$f")  FASTQC submitted: $(grep -c 'Submitted process > .*FASTQC' "$f")  all cached: $(grep -c 'Cached process' "$f")  all submitted: $(grep -c 'Submitted process' "$f")"
    line=$(grep -E "(Cached|Submitted) process > .*READ_TRIMMING:FASTQC \(S_1A_1\)" "$f" | head -n 1)
    echo "$line" | cut -c1-200
    pre=$(echo "$line" | grep -oE "\[[0-9a-f]{2}/[0-9a-f]{6}\]" | tr -d '[]/')
    [ -n "$pre" ] || continue
    # the dumped "cache hash" is not the work-dir hash: select the FASTQC dump whose meta value is id:S_1A_1
    awk '/READ_TRIMMING:FASTQC \([0-9]+\)\] cache hash:/ {b=$0; p=1; next} p {b=b "\n" $0} p && /^\]/ {if (b ~ /\[id:S_1A_1,/) {print b; exit} p=0}' "$f" > "$O/$tag.fastqc_S_1A_1.json.txt"
    echo "hash dump -> $O/$tag.fastqc_S_1A_1.json.txt ($(wc -l < "$O/$tag.fastqc_S_1A_1.json.txt") lines); cache hash: $(grep -oE 'cache hash: [0-9a-f]+' "$O/$tag.fastqc_S_1A_1.json.txt")"
done
for t in A2 C; do
    [ -f "$O/$t.fastqc_S_1A_1.json.txt" ] || continue
    echo "=================== diff baseline vs $t (FASTQC S_1A_1 hash components; timestamps stripped)"
    diff <(sed 's/^.*INFO  nextflow.processor.TaskHasher - //' "$O/baseline.fastqc_S_1A_1.json.txt") \
         <(sed 's/^.*INFO  nextflow.processor.TaskHasher - //' "$O/$t.fastqc_S_1A_1.json.txt") | cut -c1-400
done
echo "=================== md5 of FASTQC S_1A_1 outputs per task dir, zg_resources lines, sacct allocation"
for d in $(grep -lE "fastqc" $W/*/*/.command.sh 2>/dev/null | xargs -n1 dirname); do
    ls "$d"/S_1A_1_1_fastqc.zip >/dev/null 2>&1 || continue
    echo "== $d"
    grep -m1 -E "^ +--quiet" "$d/.command.sh"
    md5sum "$d"/S_1A_1_1_fastqc.zip "$d"/S_1A_1_1_fastqc.html | sed 's#/share.*/##'
    grep zg_resources "$d/.command.err"
    j=$(grep -oE "job=[0-9]+" "$d/.command.err" | head -n 1 | cut -d= -f2)
    [ -n "$j" ] && sacct -j "$j" -X -n --format=JobID,AllocCPUS,ReqMem,State,Elapsed
done
