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
# Trimmomatic-vs-cutadapt comparison on subsamples (simplify branch, trimming switch; user decisions 2026-09-29: cutadapt via
# the nf-core module; compare on 5-10 M random pairs from 4-6 samples spanning low to high depth, the same subsample fed to
# both trimmers). Inputs: the merged (demultiplexed, cropped) 1A sample FASTQs of the simplify_mem2 run (MERGE_LANES work dir),
# read-only. Writes only under $OUT. Nothing is removed.
# Submitted per task by agent/20260929_170500_submit_trim_comparison.sh (git checkout ZG_REPO on hazel):
#   subsample <sample> <pairs>   random pairs (fixed seed, same pair in R1 and R2) of the merged FASTQs -> $OUT/sub/, + metrics
#   trim <method> <sample>       trimmomatic (batch-1 parameters, as the TRIMMOMATIC module ran them) or a cutadapt variant (as
#                                the nf-core CUTADAPT module runs it: --cores = SLURM cpus, $args, -o/-p, log), + metrics
#   map <label> <r1> <r2>        first MAP_PAIRS pairs (of a random subsample) -> minibwa -x sr to B73 -> samtools stats and
#                                the primary MAPQ >= 20 count
# Metrics per FASTQ ($OUT/metrics/<label>.tsv): reads, bases, reads containing the adapter 13-mer AGATCGGAAGAGC, reads ending
# in an adapter prefix of 5-12 bases, reads ending in >= 10 G (NovaSeq X two-colour: no signal reads as high-quality G).
# (no `set -u`: hazel-debug-loop skill)
set -eo pipefail

MODE="$1"; shift
REPO="${ZG_REPO:?set ZG_REPO to the zealgt checkout}"
W=/share/maize/frodrig4/nf_work
OUT=$W/simplify_trimcmp
MERGED=$W/simplify_mem2/work/c2/bde5bbabd599d024a8b464b455a760/demux
TRIMMO_LOGS=$W/simplify_mem2/fastq_checkpoint/subsample_1200000000/1A
REF=/rsstu/users/r/rrellan/BZea/ZEAL/reference/B73.fa
MAP_PAIRS=2000000
SEED=20260929
A1=AGATCGGAAGAGCACACGTCTGAACTCCAGTCA   # TruSeq read-through adapter as read in R1
A2=AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT   # the same in R2

prefix_of() { bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' -v p="$1" '$2 == p { print $5 }'; }
CUT=$(prefix_of CUTADAPT)
ALN=$(prefix_of ALIGN_MARKDUP)
DMX=$(prefix_of DEMUX)
TRM=/share/maize/frodrig4/conda/zealgt/trimmomatic-bc6b36fd   # the TRIMMOMATIC prefix of 5f08d8c (content key, --list at 5f08d8c)
for p in "$CUT" "$ALN" "$DMX" "$TRM"; do [ -d "$p/bin" ] || { echo "env prefix missing: '$p' (build the envs first)" >&2; exit 1; }; done
CPUS=${SLURM_CPUS_PER_TASK:-8}
export PATH="$DMX/bin:$PATH"   # pigz
echo "trimcmp $MODE $* job ${SLURM_JOB_ID} on $(hostname) cpus $CPUS repo $REPO at $(git -C "$REPO" rev-parse --short HEAD)"
mkdir -p "$OUT/metrics"

fq_metrics() { # fq_metrics <label> <read 1|2> <fastq.gz>
    pigz -dc "$3" | awk -v l="$1" -v r="$2" -v a="AGATCGGAAGAGC" '
        NR % 4 == 2 {
            n++; len = length($0); b += len
            if (index($0, a) > 0) full++
            else for (k = 12; k >= 5; k--) if (len >= k && substr($0, len - k + 1) == substr(a, 1, k)) { part++; break }
            if ($0 ~ /GGGGGGGGGG$/) g++
        }
        END { printf "%s\tR%s\t%d\t%d\t%d\t%d\t%d\n", l, r, n, b, full, part, g }' >> "$OUT/metrics/$1.tsv"
}

case "$MODE" in
subsample)
    SAMPLE="$1"; PAIRS="$2"
    D=$OUT/sub
    mkdir -p "$D"
    total=$(grep -o 'Input Read Pairs: [0-9]*' "$TRIMMO_LOGS/${SAMPLE}_out.log" | awk '{ print $4 }')
    p=$(awk -v n="$PAIRS" -v t="$total" 'BEGIN { printf "%.8f", n / t }')
    echo "$SAMPLE: $total pairs, keep fraction $p (target $PAIRS)"
    paste <(pigz -dc "$MERGED/${SAMPLE}_R1.fastq.gz" | paste - - - -) <(pigz -dc "$MERGED/${SAMPLE}_R2.fastq.gz" | paste - - - -) \
        | awk -F'\t' -v p="$p" -v s="$SEED" -v o1="$D/${SAMPLE}_R1.fastq" -v o2="$D/${SAMPLE}_R2.fastq" '
            BEGIN { srand(s) }
            rand() < p { print $1 "\n" $2 "\n" $3 "\n" $4 > o1; print $5 "\n" $6 "\n" $7 "\n" $8 > o2 }'
    pigz -f -p "$CPUS" "$D/${SAMPLE}_R1.fastq" "$D/${SAMPLE}_R2.fastq"
    : > "$OUT/metrics/raw_${SAMPLE}.tsv"
    fq_metrics "raw_${SAMPLE}" 1 "$D/${SAMPLE}_R1.fastq.gz"
    fq_metrics "raw_${SAMPLE}" 2 "$D/${SAMPLE}_R2.fastq.gz"
    printf '%s\t%s\n' "$SAMPLE" "$total" > "$D/${SAMPLE}.total_pairs.tsv"
    cat "$OUT/metrics/raw_${SAMPLE}.tsv"
    ;;
trim)
    METHOD="$1"; SAMPLE="$2"
    IN=$OUT/sub
    D=$OUT/trim/${METHOD}_c${CPUS}
    mkdir -p "$D"
    cd "$D"
    if [ "$METHOD" = trimmomatic ]; then
        export PATH="$TRM/bin:$PATH"
        [ -s TruSeq3-PE-2.fa ] || cp "$REPO/assets/adapters/TruSeq3-PE-2.fa" TruSeq3-PE-2.fa
        echo "trimmomatic $(trimmomatic -version)"
        o1=${SAMPLE}.paired.trim_1.fastq.gz; o2=${SAMPLE}.paired.trim_2.fastq.gz
        t0=$(date +%s)
        /usr/bin/time -v -o "${SAMPLE}.time.txt" trimmomatic PE -threads "$CPUS" -summary "${SAMPLE}.summary" -phred33 \
            "$IN/${SAMPLE}_R1.fastq.gz" "$IN/${SAMPLE}_R2.fastq.gz" \
            "$o1" "${SAMPLE}.unpaired.trim_1.fastq.gz" "$o2" "${SAMPLE}.unpaired.trim_2.fastq.gz" \
            ILLUMINACLIP:TruSeq3-PE-2.fa:2:30:10 LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36 2> "${SAMPLE}_out.log"
        t1=$(date +%s)
    else
        case "$METHOD" in
            nt15)    ARGS="--nextseq-trim=15 -m 36" ;;
            q3_15)   ARGS="-q 3,15 -m 36" ;;
            nt15_q3) ARGS="--nextseq-trim=15 -q 3,0 -m 36" ;;
            nt15_Z)  ARGS="--nextseq-trim=15 -m 36 -Z" ;;
            *) echo "unknown method $METHOD" >&2; exit 1 ;;
        esac
        export PATH="$CUT/bin:$PATH"
        echo "cutadapt $(cutadapt --version): -a $A1 -A $A2 $ARGS"
        o1=${SAMPLE}_1.trim.fastq.gz; o2=${SAMPLE}_2.trim.fastq.gz
        t0=$(date +%s)
        /usr/bin/time -v -o "${SAMPLE}.time.txt" cutadapt --cores "$CPUS" -a "$A1" -A "$A2" $ARGS --json "${SAMPLE}.cutadapt.json" \
            -o "$o1" -p "$o2" "$IN/${SAMPLE}_R1.fastq.gz" "$IN/${SAMPLE}_R2.fastq.gz" > "${SAMPLE}.cutadapt.log"
        t1=$(date +%s)
    fi
    rss=$(awk -F': ' '/Maximum resident set size/ { print $2 }' "${SAMPLE}.time.txt")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$METHOD" "$CPUS" "$SAMPLE" "$((t1 - t0))" "$rss" \
        "$(stat -c %s "$o1" "$o2" | paste -sd+ | bc)" > "${SAMPLE}.run.tsv"
    L=${METHOD}_c${CPUS}_${SAMPLE}
    : > "$OUT/metrics/$L.tsv"
    fq_metrics "$L" 1 "$o1"
    fq_metrics "$L" 2 "$o2"
    cat "${SAMPLE}.run.tsv" "$OUT/metrics/$L.tsv"
    ;;
map)
    LABEL="$1"; R1="$2"; R2="$3"
    D=$OUT/map/$LABEL
    mkdir -p "$D"
    cd "$D"
    export PATH="$ALN/bin:$PATH"
    n=$((MAP_PAIRS * 4))
    set +o pipefail
    pigz -dc "$R1" | head -n "$n" > r1.fq
    pigz -dc "$R2" | head -n "$n" > r2.fq
    set -o pipefail
    minibwa map -t "$CPUS" -x sr "$REF" r1.fq r2.fq \
        | samtools view -@ 2 -u - \
        | tee >(samtools view -c -q 20 -F 0x904 - > mapq20_primary.txt) \
        | samtools stats -@ 2 - > stats.txt
    sleep 5
    grep ^SN stats.txt | cut -f 2- > sn.tsv
    : > r1.fq
    : > r2.fq   # truncated, kept as empty files (no rm)
    head -n 40 sn.tsv
    cat mapq20_primary.txt
    ;;
*)
    echo "unknown mode $MODE" >&2; exit 1 ;;
esac
