#!/usr/bin/env bash
# scripts/check_resources.sh — check the resources each process actually gets on hazel (cpus, memory, time, queue), as
# resolved by Nextflow from conf/hazel.config + conf/normal.config (and + conf/short.config), against the intended values in
# tests/expected_resources.tsv. Catches selector-precedence losses that no lint sees (Gate 2: normal.config's TRIMMOMATIC
# 12 h block lost to the combined DEMUX|TRIMMOMATIC|... selector and never applied).
#
#   bash scripts/check_resources.sh [--expected <tsv>]        (laptop; on hazel only inside a Slurm job)
#
# How: per profile pair (hazel,normal and hazel,short) a -stub run of both CRAM entries (read_demultiplexing on the test
# fixture library LIBX, markdup_import on touch-file CRAMs) and of the 7 genotype entries (tests/fixtures/genotype, each on
# a store seeded with the earlier stages' outputs) with the real profiles (-profile hazel,<p>), plus an override
# config that only swaps the executor to local with a large pool (64 cpus, 1 TB: nothing is capped by the laptop), turns
# conda and Apptainer off (tasks on the host, as the stub shims expect), and puts work/, TMPDIR (+ its beforeScript), an outdir (the store_stub* store) and a checkpoint_stub* FASTQ checkpoint under the scratch dir. The trace's cpus / memory / time / queue per process (first attempt; stub tasks do not
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
OBS="$SCRATCH/obs"; mkdir -p "$OBS"
# The 22 stub runs (per profile: 2 CRAM entries, 7 genotype entries, variant_discovery in mpileup mode, the size probe)
# are independent: each has its own launch directory, work dir and store. They run as a pool of ZG_RES_JOBS (default 4)
# background jobs; each writes its trace rows to obs/<nn>.tsv and its exit status to obs/<nn>.status, merged in run order
# afterwards (the comparison below is order-insensitive anyway). Their tasks are stub touches and the recorded cpus /
# memory are requests, not use: the real load is one Nextflow JVM per run.
JOBS_MAX="${ZG_RES_JOBS:-4}"
RUNS_TOTAL=22; RUN_N=0; T0=$(date +%s)
declare -a RUN_LABEL RUN_LOG
# "== " marks the progress lines (grep '== '); the time only when run alone (run_checks.sh stamps every line itself)
stamp() { printf '== %s%s (%d s elapsed)\n' "$([ -n "${ZG_LOG_STAMPED:-}" ] || date '+[%H:%M:%S] ')" "$*" "$(( $(date +%s) - T0 ))"; }

# run_job <nn> <label> <rowkey: profile | profile_tag> <dir> <log> <trace> <command...>: one stub run in the background
run_job() {
    local nn="$1" label="$2" rowkey="$3" dir="$4" log="$5" trace="$6"; shift 6
    local t=$(date +%s) st=0
    ( cd "$dir" && "$@" > "$log" 2>&1 ) || st=$?
    echo "$st" > "$OBS/$nn.status"
    if [ "$st" -eq 0 ]; then
        awk -F'\t' -v p="$rowkey" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
            { n = split($c["process"], a, ":"); k = (p ~ /_tag$/) ? substr(p, 1, length(p) - 4) "_" $c["tag"] : p
              print k "\t" a[n] "\t" $c["cpus"] "\t" $c["memory"] "\t" $c["time"] "\t" $c["queue"] }' "$trace" > "$OBS/$nn.tsv"
    fi
    stamp "done  $nn/$RUNS_TOTAL $([ "$st" -eq 0 ] && echo ok || echo "FAILED (exit $st)")  $label  ($(( $(date +%s) - t )) s)"
}
# submit <label> <rowkey> <dir> <log> <trace> <command...>: wait for a free slot, then start run_job in the background
submit() {
    RUN_N=$((RUN_N + 1)); local nn; nn=$(printf '%02d' "$RUN_N")
    RUN_LABEL[$RUN_N]="$1"; RUN_LOG[$RUN_N]="$4"
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS_MAX" ]; do sleep 1; done
    stamp "start $nn/$RUNS_TOTAL  $1"
    run_job "$nn" "$@" &
}

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

# setup (sequential): per profile the override configs and the seeded genotype stores
for prof in normal short; do
    D="$SCRATCH/$prof"
    mkdir -p "$D"
    cat > "$D/override.config" <<EOF
// scripts/check_resources.sh override: only where tasks run, never what they request
executor {
    name         = 'local'
    cpus         = 64
    memory       = '1 TB'
    queueSize    = 100
    pollInterval = '1 sec'   // hazel.config's Slurm interval (10 s) would idle every dependency step of these instant stub tasks
}
process.executor = 'local'
conda.enabled    = false
apptainer.enabled = false   // hazel.config turns it on; its cache dir is on /share, absent on the laptop
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
    cp "$D/override.config" "$D/genotype_override.config"
    cat >> "$D/genotype_override.config" <<'EOF'
// genotype fixture params (conf/test_genotype.config), later than the params block above, so they win
params {
    workflow               = 'genotype'
    genotype_input         = "${projectDir}/tests/fixtures/genotype/genotype_samples_test.csv"
    cram_store             = "${projectDir}/tests/fixtures/genotype/cram_store"
    fasta                  = "${projectDir}/tests/fixtures/genotype/ref/tiny10.fa"
    lowcopy_bed            = "${projectDir}/tests/fixtures/genotype/lowcopy.bed"
    qc_panel               = "${projectDir}/tests/fixtures/genotype/panel.tsv"
    mappability_priors     = "${projectDir}/tests/fixtures/genotype/priors"
    reference_donor_tables = "Zx.9002_P1=${projectDir}/tests/fixtures/genotype/reference/Zx.9002_P1.sites.tsv.gz"
    regions                = 'chr10:1-16000'
    donors                 = 'Zx.9001_P1'
    donor_set              = 'test_set'
    genotype_store_key     = 'test'
    b73_controls           = 'B73_CTL'
    rigidity               = 3
    rigidity_ref_markers   = 0
    panel_min_markers      = 4
}
EOF
    sed "s/^trace.fields .*/trace.fields     = 'process,tag,cpus,memory,time,queue'/" "$D/override.config" > "$D/probe_override.config"
    seed="$REPO/tests/fixtures/genotype/store_seed/genotype/test"
    kinds=""
    for entry in sample_quality_control variant_discovery ancestry_inference marker_union donor_allele_calling genotype_imputation reporting; do
        G="$D/genotype_$entry"
        mkdir -p "$G/store_stub/genotype/test"
        for k in $kinds; do cp -R "$seed/$k" "$G/store_stub/genotype/test/"; done
        case "$entry" in
            sample_quality_control) kinds="sample_qc" ;;
            variant_discovery) kinds="$kinds step4" ;;
            ancestry_inference) kinds="$kinds ancestry" ;;
            marker_union) kinds="$kinds union" ;;
            donor_allele_calling) kinds="$kinds donor_alleles" ;;
            genotype_imputation) kinds="$kinds genotypes" ;;
        esac
    done
    # BC1_SITE_COUNTS runs only with --tier_counts_source mpileup: variant_discovery once more in that mode
    G="$D/genotype_variant_discovery_mpileup"
    mkdir -p "$G/store_stub/genotype/test"
    cp -R "$seed/sample_qc" "$G/store_stub/genotype/test/"
done

# the pool
stamp "check_resources: $RUNS_TOTAL stub runs, $JOBS_MAX at a time"
for prof in normal short; do
    D="$SCRATCH/$prof"
    for entry in read_demultiplexing markdup_import; do
        C="$D/cram_$entry"; mkdir -p "$C"      # own launch dir, work dir, store and checkpoint per CRAM entry
        submit "hazel,$prof  --entry $entry" "$prof" "$C" "$C/nextflow.log" "$C/trace.txt" \
            nextflow run "$REPO" -profile "hazel,$prof" -stub -c "$D/override.config" -w "$C/work" \
            --run_id "check_resources_$prof" --entry "$entry" --outdir "$C/store_stub" \
            --fastq_checkpoint "$C/checkpoint_stub" -with-trace "$C/trace.txt"
    done
    for entry in sample_quality_control variant_discovery ancestry_inference marker_union donor_allele_calling genotype_imputation reporting; do
        G="$D/genotype_$entry"
        submit "hazel,$prof  --workflow genotype --entry $entry" "$prof" "$G" "$G/nextflow.log" "$G/trace.txt" \
            nextflow run "$REPO" -profile "hazel,$prof" -stub -c "$D/genotype_override.config" -w "$G/work" \
            --run_id "check_resources_genotype_$prof" --entry "$entry" --outdir "$G/store_stub" \
            -with-trace "$G/trace.txt"
    done
    G="$D/genotype_variant_discovery_mpileup"
    submit "hazel,$prof  --workflow genotype --entry variant_discovery --tier_counts_source mpileup" "$prof" "$G" "$G/nextflow.log" "$G/trace.txt" \
        nextflow run "$REPO" -profile "hazel,$prof" -stub -c "$D/genotype_override.config" -w "$G/work" \
        --run_id "check_resources_genotype_$prof" --entry variant_discovery --tier_counts_source mpileup --outdir "$G/store_stub" \
        -with-trace "$G/trace.txt"
    Q="$D/probe"; mkdir -p "$Q"
    submit "hazel,$prof  size probe (100 M / 310 M pairs)" "${prof}_tag" "$Q" "$Q/nextflow.log" "$Q/trace.txt" \
        nextflow run "$P/main.nf" -c "$REPO/conf/hazel.config" -c "$REPO/conf/$prof.config" -c "$D/probe_override.config" \
        -w "$Q/work" --run_id "check_resources_probe_$prof" --align_memory_gb 48 --probe_in "$P/in" -with-trace "$Q/trace.txt"
done
wait
[ "$RUN_N" -eq "$RUNS_TOTAL" ] || { echo "check_resources: $RUN_N runs submitted, expected $RUNS_TOTAL (update RUNS_TOTAL)" >&2; exit 1; }
for i in $(seq 1 "$RUNS_TOTAL"); do
    nn=$(printf '%02d' "$i")
    if [ "$(cat "$OBS/$nn.status" 2>/dev/null || echo missing)" != 0 ]; then
        echo "check_resources: stub run $nn failed (${RUN_LABEL[$i]}), see ${RUN_LOG[$i]}" >&2; tail -20 "${RUN_LOG[$i]}" >&2; exit 1
    fi
    cat "$OBS/$nn.tsv" >> "$SCRATCH/observed.tsv"
done
stamp "check_resources: all $RUNS_TOTAL stub runs done"

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
