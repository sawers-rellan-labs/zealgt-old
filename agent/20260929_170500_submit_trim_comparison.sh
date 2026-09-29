#!/bin/bash
# Submits the Trimmomatic-vs-cutadapt comparison jobs (agent/20260929_170000_compare_trimming.sbatch) on hazel.
# Run from the laptop: ssh hazel 'bash -s' < agent/20260929_170500_submit_trim_comparison.sh
# Job ids -> /share/maize/frodrig4/nf_work/simplify_trimcmp/jobs.tsv. Nothing is removed.
set -eo pipefail
REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-simplify
S=$REPO/agent/20260929_170000_compare_trimming.sbatch
W=/share/maize/frodrig4/nf_work
OUT=$W/simplify_trimcmp
IN=$W/simplify_mem2/work/c2/bde5bbabd599d024a8b464b455a760/demux
TRIMMO=$W/simplify_mem2/fastq_checkpoint/subsample_1200000000/1A
mkdir -p "$OUT/logs"
J=$OUT/jobs.tsv
[ -s "$J" ] || printf 'job\tmode\targs\n' > "$J"
echo "repo $REPO at $(git -C "$REPO" rev-parse --short HEAD)" | tee -a "$J"

sub() { # sub <sbatch options...> -- <mode> <args...>
    local opts=()
    while [ "$1" != "--" ]; do opts+=("$1"); shift; done
    shift
    local id
    id=$(sbatch --parsable --export=ALL,ZG_REPO="$REPO" "${opts[@]}" "$S" "$@")
    printf '%s\t%s\n' "$id" "$*" >> "$J"
    echo "$id"
}

ALL="S_1A_1 S_1A_2 S_1A_3 S_1A_4 S_1A_5 S_1A_6 S_1A_7 S_1A_8 S_1A_9 S_1A_10 S_1A_11 S_1A_12"
MAPSET="S_1A_12 S_1A_10 S_1A_6"

declare -A TRIMJOB
for s in $ALL; do
    TRIMJOB[nt15_$s]=$(sub --cpus-per-task=8 --mem=4G -- trim nt15 "$s")
    sub --cpus-per-task=2 --mem=2G -- count "trimmomatic_$s" "$TRIMMO/$s.paired.trim_1.fastq.gz" "$TRIMMO/$s.paired.trim_2.fastq.gz" > /dev/null
done
for s in $MAPSET; do
    for v in q3_15 nt15_q3 nt15_Z; do
        TRIMJOB[${v}_$s]=$(sub --cpus-per-task=8 --mem=4G -- trim "$v" "$s")
    done
done
for s in S_1A_10 S_1A_6; do
    sub --cpus-per-task=4 --mem=4G -- trim nt15 "$s" > /dev/null
done
for s in $MAPSET; do
    sub -- map "raw_$s" "$IN/${s}_R1.fastq.gz" "$IN/${s}_R2.fastq.gz" > /dev/null
    sub -- map "trimmomatic_$s" "$TRIMMO/$s.paired.trim_1.fastq.gz" "$TRIMMO/$s.paired.trim_2.fastq.gz" > /dev/null
    for v in nt15 q3_15 nt15_q3 nt15_Z; do
        D=$OUT/trim/${v}_c8
        sub --dependency=afterok:${TRIMJOB[${v}_$s]} --kill-on-invalid-dep=yes -- map "${v}_$s" "$D/${s}_1.trim.fastq.gz" "$D/${s}_2.trim.fastq.gz" > /dev/null
    done
done
cat "$J"
