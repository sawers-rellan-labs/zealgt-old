#!/bin/bash
#SBATCH --job-name=zg_trimcmp
#SBATCH --account=maize_cpu
#SBATCH --partition=compute_partners
#SBATCH --qos=short
#SBATCH --time=01:55:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --output=/share/maize/frodrig4/nf_work/simplify_trimcmp/logs/%x_%j.log
#
# Trimmomatic-vs-cutadapt comparison (simplify branch, trimming switch; user decision 2026-09-29).
# Inputs: the merged (demultiplexed, cropped) 1A sample FASTQs of the simplify_mem2 run (MERGE_LANES work dir) and the
# Trimmomatic outputs of the same run (FASTQ checkpoint, batch-1 parameters ILLUMINACLIP 2:30:10 LEADING:3 TRAILING:3
# SLIDINGWINDOW:4:15 MINLEN:36, 8 threads). Read-only on those; writes only under $OUT. Nothing is removed.
# Submitted per task by agent/20260929_170500_submit_trim_comparison.sh (git checkout ZG_REPO on hazel):
#   trim <variant> <sample>           cutadapt as the nf-core CUTADAPT module runs it (--cores = SLURM cpus, $args, -o/-p, log)
#   map  <label> <r1> <r2>            first MAP_PAIRS pairs -> minibwa -x sr to B73 -> samtools stats + MAPQ>=20 count;
#                                     poly-G tails (last 10 bases all G) on the same subset
#   count <label> <r1> <r2>           pairs and bases of a (Trimmomatic) output pair
# (no `set -u`: hazel-debug-loop skill)
set -eo pipefail

MODE="$1"; shift
REPO="${ZG_REPO:?set ZG_REPO to the zealgt checkout}"
W=/share/maize/frodrig4/nf_work
OUT=$W/simplify_trimcmp
REF=/rsstu/users/r/rrellan/BZea/ZEAL/reference/B73.fa
MAP_PAIRS=2000000
A1=AGATCGGAAGAGCACACGTCTGAACTCCAGTCA   # TruSeq read-through adapter as read in R1 (Illumina adapter, 3' of R1)
A2=AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT   # the same in R2

prefix_of() { bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' -v p="$1" '$2 == p { print $5 }'; }
CUT=$(prefix_of CUTADAPT)
ALN=$(prefix_of ALIGN_MARKDUP)
DMX=$(prefix_of DEMUX)
for p in "$CUT" "$ALN" "$DMX"; do [ -d "$p/bin" ] || { echo "env prefix missing: '$p' (build the envs first)" >&2; exit 1; }; done
CPUS=${SLURM_CPUS_PER_TASK:-8}
echo "trimcmp $MODE $* job ${SLURM_JOB_ID} on $(hostname) cpus $CPUS repo $REPO at $(git -C "$REPO" rev-parse --short HEAD)"

case "$MODE" in
trim)
    VARIANT="$1"; SAMPLE="$2"
    IN=$W/simplify_mem2/work/c2/bde5bbabd599d024a8b464b455a760/demux
    case "$VARIANT" in
        nt15)    ARGS="--nextseq-trim=15 -m 36" ;;
        q3_15)   ARGS="-q 3,15 -m 36" ;;
        nt15_q3) ARGS="--nextseq-trim=15 -q 3,0 -m 36" ;;
        nt15_Z)  ARGS="--nextseq-trim=15 -m 36 -Z" ;;
        *) echo "unknown variant $VARIANT" >&2; exit 1 ;;
    esac
    D=$OUT/trim/${VARIANT}_c${CPUS}
    mkdir -p "$D"
    cd "$D"
    export PATH="$CUT/bin:$PATH"
    echo "cutadapt $(cutadapt --version): -a $A1 -A $A2 $ARGS"
    t0=$(date +%s)
    /usr/bin/time -v -o "${SAMPLE}.time.txt" cutadapt --cores "$CPUS" -a "$A1" -A "$A2" $ARGS --json "${SAMPLE}.cutadapt.json" \
        -o "${SAMPLE}_1.trim.fastq.gz" -p "${SAMPLE}_2.trim.fastq.gz" \
        "$IN/${SAMPLE}_R1.fastq.gz" "$IN/${SAMPLE}_R2.fastq.gz" > "${SAMPLE}.cutadapt.log"
    t1=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$VARIANT" "$CPUS" "$SAMPLE" "$((t1 - t0))" \
        "$(stat -c %s "$IN/${SAMPLE}_R1.fastq.gz" "$IN/${SAMPLE}_R2.fastq.gz" | paste -sd+ | bc)" \
        "$(stat -c %s "${SAMPLE}_1.trim.fastq.gz" "${SAMPLE}_2.trim.fastq.gz" | paste -sd+ | bc)" > "${SAMPLE}.wall.tsv"
    cat "${SAMPLE}.wall.tsv"
    ;;
map)
    LABEL="$1"; R1="$2"; R2="$3"
    D=$OUT/map/$LABEL
    mkdir -p "$D"
    cd "$D"
    export PATH="$ALN/bin:$DMX/bin:$PATH"
    n=$((MAP_PAIRS * 4))
    set +o pipefail
    pigz -dc "$R1" | head -n "$n" > r1.fq
    pigz -dc "$R2" | head -n "$n" > r2.fq
    set -o pipefail
    for r in 1 2; do
        awk -v r="$r" 'NR % 4 == 2 { n++; b += length($0); if ($0 ~ /GGGGGGGGGG$/) g++ } END { printf "R%s\treads\t%d\tbases\t%d\tpolyG10_tail\t%d\n", r, n, b, g }' "r$r.fq"
    done > subset.tsv
    minibwa map -t "$CPUS" -x sr "$REF" r1.fq r2.fq \
        | samtools view -@ 2 -u - \
        | tee >(samtools view -c -q 20 -F 0x904 - > mapq20_primary.txt) \
        | samtools stats -@ 2 - > stats.txt
    sleep 5
    grep ^SN stats.txt | cut -f 2- > sn.tsv
    : > r1.fq; : > r2.fq   # truncate the subset copies (kept as empty files; no rm)
    cat subset.tsv; head -n 40 sn.tsv; cat mapq20_primary.txt
    ;;
count)
    LABEL="$1"; R1="$2"; R2="$3"
    D=$OUT/count
    mkdir -p "$D"
    export PATH="$DMX/bin:$PATH"
    for r in "$R1" "$R2"; do
        pigz -dc "$r" | awk 'NR % 4 == 2 { n++; b += length($0) } END { printf "%d\t%d\n", n, b }'
    done | paste -s - | awk -v l="$LABEL" '{ print l "\t" $1 "\t" $2 + $4 "\t" $2 "\t" $4 }' > "$D/$LABEL.tsv"
    cat "$D/$LABEL.tsv"
    ;;
*)
    echo "unknown mode $MODE" >&2; exit 1 ;;
esac
