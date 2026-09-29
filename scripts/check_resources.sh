#!/usr/bin/env bash
# scripts/check_resources.sh — check the resources each process actually gets on hazel (cpus, memory, time, queue), as
# resolved by Nextflow from conf/hazel.config + conf/normal.config (and + conf/short.config), against the intended values in
# tests/expected_resources.tsv. Catches selector-precedence losses that no lint sees (Gate 2: normal.config's TRIMMOMATIC
# 12 h block lost to the combined DEMUX|TRIMMOMATIC|... selector and never applied).
#
#   bash scripts/check_resources.sh [--expected <tsv>]        (laptop; on hazel only inside a Slurm job)
#
# How: per profile pair (hazel,normal and hazel,short) a -stub run of both CRAM entries (read_demultiplexing on the test
# fixture library LIBX, markdup_import on touch-file CRAMs) with the real profiles (-profile hazel,<p>), plus an override
# config that only swaps the executor to local with a large pool (64 cpus, 1 TB: nothing is capped by the laptop), turns
# conda off, and puts work/, TMPDIR (+ its beforeScript), outdir, a store_stub* store and a checkpoint_stub* FASTQ checkpoint under the scratch dir. The trace's cpus / memory / time / queue per process (first attempt; stub tasks do not
# retry) are compared with the table: every observed process needs a row, every row must be observed, values must match.
# Then a size probe (conf/hazel.config scales the per-sample times with the input size and conf/normal.config routes each
# task by its time; the fixtures only reach the 15 min floor): five stand-in processes on sparse 100 M / 310 M pair
# inputs, rows <profile>_100M / <profile>_310M.
# Also checked (`nextflow config -flat -profile hazel,normal`): hazel.config's beforeScript creates exactly env.TMPDIR.
# Exit 1 on any mismatch. Stub runs evaluate the nf-core modules' `eval` versions, so the tools or version shims must be on
# PATH (ZG_CHECK_PATH, as for scripts/run_checks.sh). Scratch: $ZG_RES_SCRATCH (default agent/check_resources/<time>).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -z "${ZG_CHECK_PATH:-}" ] || export PATH="$ZG_CHECK_PATH:$PATH"
export NXF_ANSI_LOG=false
EXPECTED="$REPO/tests/expected_resources.tsv"
if [ "${1:-}" = "--expected" ]; then
    EXPECTED="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
[ -s "$EXPECTED" ] || { echo "check_resources: expected table $EXPECTED missing" >&2; exit 2; }
SCRATCH="${ZG_RES_SCRATCH:-$REPO/agent/check_resources/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$SCRATCH"
echo "check_resources: scratch $SCRATCH, expected $EXPECTED"

# import sheet for markdup_import: two touch-file CRAMs (as tests/default.nf.test)
IMP="$SCRATCH/imp"
mkdir -p "$IMP"
for s in IMP_A IMP_B; do : > "$IMP/$s.cram"; : > "$IMP/$s.cram.crai"; done
cat > "$SCRATCH/import.csv" <<EOF
sample_id,source,role,library,donor,import_set,path,index,size_bytes,made_by,dup_marked,read_groups,include,note
IMP_A,bc1,bc1_sample,2A,Zx.0540_P3,Zx.0540_P3,$IMP/IMP_A.cram,$IMP/IMP_A.cram.crai,10,nilhmm pool_run,no,no,TRUE,
IMP_B,bc2s3_batch1,line,BZea5,Zx.0540_P3,Zx.0540_P3,$IMP/IMP_B.cram,$IMP/IMP_B.cram.crai,10,zealbc1 bc2s3_realign,no,no,TRUE,
EOF

rc=0
: > "$SCRATCH/observed.tsv"
for prof in normal short; do
    D="$SCRATCH/$prof"
    mkdir -p "$D"
    cat > "$D/override.config" <<EOF
// scripts/check_resources.sh override: only where tasks run, never what they request
executor {
    name      = 'local'
    cpus      = 64
    memory    = '1 TB'
    queueSize = 100
}
process.executor = 'local'
conda.enabled    = false
env.TMPDIR       = '$D/tmp'
process.beforeScript = "mkdir -p '$D/tmp'"
trace.fields     = 'process,name,attempt,status,cpus,memory,time,queue'
trace.overwrite  = true
params {
    input        = "\${projectDir}/tests/fixtures/samples_test.csv"
    libraries    = 'LIBX'
    fasta        = "\${projectDir}/tests/fixtures/ref/tiny.fa"
    import_sheet = '$SCRATCH/import.csv'
}
EOF
    for entry in read_demultiplexing markdup_import; do
        echo "== hazel,$prof  --entry $entry"
        ( cd "$D" && nextflow run "$REPO" -profile "hazel,$prof" -stub -c "$D/override.config" -w "$D/work" \
            --run_id "check_resources_$prof" --entry "$entry" --outdir "$D/results_$entry" --store "$D/store_stub" \
            --fastq_checkpoint "$D/checkpoint_stub" \
            -with-trace "$D/trace_$entry.txt" > "$D/nextflow_$entry.log" 2>&1 ) \
            || { echo "check_resources: stub run failed (hazel,$prof $entry), see $D/nextflow_$entry.log" >&2; tail -20 "$D/nextflow_$entry.log" >&2; exit 1; }
        grep -E "Succeeded|succeeded" "$D/nextflow_$entry.log" | tail -1 || true
        awk -F'\t' -v p="$prof" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
            { n = split($c["process"], a, ":"); print p "\t" a[n] "\t" $c["cpus"] "\t" $c["memory"] "\t" $c["time"] "\t" $c["queue"] }' \
            "$D/trace_$entry.txt" >> "$SCRATCH/observed.tsv"
    done
done

# Size probe: the fixture and stub inputs are tiny, so the stub runs above only see hazel.config's 15 min time floor (and
# normal.config's routing of it to short QOS). A probe script with the five size-scaled processes (same names and input
# variable names as the modules: `reads`, `input`, `bam`) runs with
# conf/hazel.config + conf/normal.config (or + conf/short.config) on sparse input files of a 100 M and a 310 M pair sample
# (Gate 2 sizes: 136 B per raw pair, 107 B per trimmed pair, 41 B of CRAM per pair; sparse, so no disk is used). Rows are
# keyed <profile>_<size> (normal_100M, normal_310M, short_100M, short_310M); plus <profile>_batch1: a DEMUX stand-in of source
# bc2s3_batch1 (fixed 2 h, whatever its tar inputs weigh -> compute / normal on `normal`).
P="$SCRATCH/probe"
mkdir -p "$P/in"
python3 - "$P/in" <<'PY'
import os, sys
for tag, pairs in (('100M', 100e6), ('310M', 310e6)):
    for name, size in (('raw_1.fastq.gz', pairs * 136 / 2), ('raw_2.fastq.gz', pairs * 136 / 2),
                       ('trim_1.fastq.gz', pairs * 107 / 2), ('trim_2.fastq.gz', pairs * 107 / 2),
                       ('x.cram', pairs * 41), ('x.cram.crai', 0)):
        with open(os.path.join(sys.argv[1], f'{tag}_{name}'), 'wb') as f:
            f.truncate(int(size))
PY
cat > "$P/main.nf" <<'EOF'
// scripts/check_resources.sh size probe: only the processes' names and input names matter (the time closure reads them)
process DEMUX {
    tag "${meta.tag}"
    input:
    val meta
    script:
    "true"
}
process CUTADAPT {
    tag "${meta}"
    input:
    tuple val(meta), path(reads)
    script:
    "true"
}
process FASTQC {
    tag "${meta}"
    input:
    tuple val(meta), path(reads, stageAs: '?/*')
    script:
    "true"
}
process ALIGN_MARKDUP {
    tag "${meta}"
    input:
    tuple val(meta), path(reads)
    script:
    "true"
}
process SAMTOOLS_STATS {
    tag "${meta}"
    input:
    tuple val(meta), path(input), path(input_index)
    script:
    "true"
}
process PICARD_COLLECTWGSMETRICS {
    tag "${meta}"
    input:
    tuple val(meta), path(bam), path(bai)
    script:
    "true"
}
workflow {
    def d = params.probe_in
    DEMUX(channel.of([tag: 'batch1', source: 'bc2s3_batch1']))
    CUTADAPT(channel.of('100M', '310M').map { s -> [s, [file("${d}/${s}_raw_1.fastq.gz"), file("${d}/${s}_raw_2.fastq.gz")]] })
    FASTQC(channel.of('100M', '310M').map { s -> [s, [file("${d}/${s}_trim_1.fastq.gz"), file("${d}/${s}_trim_2.fastq.gz")]] })
    ALIGN_MARKDUP(channel.of('100M', '310M').map { s -> [s, [file("${d}/${s}_trim_1.fastq.gz"), file("${d}/${s}_trim_2.fastq.gz")]] })
    SAMTOOLS_STATS(channel.of('100M', '310M').map { s -> [s, file("${d}/${s}_x.cram"), file("${d}/${s}_x.cram.crai")] })
    PICARD_COLLECTWGSMETRICS(channel.of('100M', '310M').map { s -> [s, file("${d}/${s}_x.cram"), file("${d}/${s}_x.cram.crai")] })
}
EOF
for prof in normal short; do
    D="$SCRATCH/$prof"
    sed "s/^trace.fields .*/trace.fields     = 'process,tag,cpus,memory,time,queue'/" "$D/override.config" > "$D/probe_override.config"
    echo "== hazel,$prof  size probe (100 M / 310 M pairs)"
    ( cd "$D" && nextflow run "$P/main.nf" -c "$REPO/conf/hazel.config" -c "$REPO/conf/$prof.config" -c "$D/probe_override.config" \
        -w "$D/work_probe" --run_id "check_resources_probe_$prof" --align_memory_gb 48 --probe_in "$P/in" \
        -with-trace "$D/trace_probe.txt" > "$D/nextflow_probe.log" 2>&1 ) \
        || { echo "check_resources: size probe failed (hazel,$prof), see $D/nextflow_probe.log" >&2; tail -20 "$D/nextflow_probe.log" >&2; exit 1; }
    awk -F'\t' -v p="$prof" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        { n = split($c["process"], a, ":"); print p "_" $c["tag"] "\t" a[n] "\t" $c["cpus"] "\t" $c["memory"] "\t" $c["time"] "\t" $c["queue"] }' \
        "$D/trace_probe.txt" >> "$SCRATCH/observed.tsv"
done

# hazel.config's beforeScript must create exactly env.TMPDIR (it runs before the env exports, so it spells the path out)
flat="$(cd "$SCRATCH" && nextflow config "$REPO" -flat -profile hazel,normal)"
tmpdir="$(printf '%s\n' "$flat" | sed -n "s/^env\.TMPDIR = '\(.*\)'\$/\1/p")"
before="$(printf '%s\n' "$flat" | sed -n 's/^process\.beforeScript = //p')"
if [ -n "$tmpdir" ] && [ "$before" = "'mkdir -p \\'$tmpdir\\''" ]; then
    echo "ok        hazel   beforeScript creates env.TMPDIR ($tmpdir)"
else
    echo "MISMATCH  hazel   process.beforeScript ($before) does not create env.TMPDIR ('$tmpdir'), conf/hazel.config" >&2
    rc=1
fi

python3 - "$EXPECTED" "$SCRATCH/observed.tsv" <<'PY' || rc=1
import sys
expected, observed = {}, {}
for line in open(sys.argv[1]):
    if line.startswith('#') or not line.strip():
        continue
    f = line.rstrip('\n').split('\t')
    if f[0] == 'profile':
        continue
    expected[(f[0], f[1])] = tuple(f[2:6])
for line in open(sys.argv[2]):
    f = line.rstrip('\n').split('\t')
    observed.setdefault((f[0], f[1]), set()).add(tuple(f[2:6]))
bad = 0
for key in sorted(set(expected) | set(observed)):
    exp, obs = expected.get(key), observed.get(key)
    if exp is None:
        print(f'NO ROW    {key[0]:7s} {key[1]:26s} observed {sorted(obs)} (add it to the table)'); bad += 1
    elif obs is None:
        print(f'NOT RUN   {key[0]:7s} {key[1]:26s} expected {exp} (no task of this process ran)'); bad += 1
    elif obs != {exp}:
        print(f'MISMATCH  {key[0]:7s} {key[1]:26s} expected cpus/memory/time/queue {exp}, got {sorted(obs)}'); bad += 1
    else:
        print(f'ok        {key[0]:7s} {key[1]:26s} {" / ".join(exp)}')
print(f'check_resources: {len(expected)} rows, {bad} problem(s)')
sys.exit(1 if bad else 0)
PY
[ "$rc" -eq 0 ] && echo "check_resources: passed" || echo "check_resources: FAILED" >&2
exit "$rc"
