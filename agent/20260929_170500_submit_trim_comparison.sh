#!/bin/bash
# Submits the Trimmomatic-vs-cutadapt comparison jobs (agent/20260929_170000_compare_trimming.sbatch) on hazel:
# 8 M random pairs from each of 5 1A samples spanning low to high depth; the same subsample goes to Trimmomatic (batch-1
# parameters) and to each cutadapt variant; the first 2 M pairs of every output (and of the raw subsample) are mapped.
# Run from the laptop: ssh hazel 'bash -s' < agent/20260929_170500_submit_trim_comparison.sh
# Job ids -> /share/maize/frodrig4/nf_work/simplify_trimcmp/jobs.tsv. Nothing is removed.
set -eo pipefail
REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-simplify
S=$REPO/agent/20260929_170000_compare_trimming.sbatch
OUT=/share/maize/frodrig4/nf_work/simplify_trimcmp
PAIRS=8000000
mkdir -p "$OUT/logs"
J=$OUT/jobs.tsv
[ -s "$J" ] || printf 'job\targs\n' > "$J"
echo "# repo $REPO at $(git -C "$REPO" rev-parse --short HEAD), $(date '+%F %T')" >> "$J"

sub() { # sub <sbatch options...> -- <mode> <args...>
    local opts=()
    while [ "$1" != "--" ]; do opts+=("$1"); shift; done
    shift
    local id
    id=$(sbatch --parsable --export=ALL,ZG_REPO="$REPO" "${opts[@]}" "$S" "$@")
    printf '%s\t%s\n' "$id" "$*" >> "$J"
    echo "$id"
}

# low -> high depth (simplify_mem2 Trimmomatic input pairs): S_1A_12, S_1A_10, S_1A_1, S_1A_3, S_1A_6
SAMPLES="S_1A_12 S_1A_10 S_1A_1 S_1A_3 S_1A_6"
METHODS="trimmomatic nt15 q3_15 nt15_q3 nt15_Z"
for s in $SAMPLES; do
    sj=$(sub --cpus-per-task=4 --mem=4G -- subsample "$s" "$PAIRS")
    sub --dependency=afterok:$sj --kill-on-invalid-dep=yes -- map "raw_$s" "$OUT/sub/${s}_R1.fastq.gz" "$OUT/sub/${s}_R2.fastq.gz" > /dev/null
    for m in $METHODS; do
        tj=$(sub --dependency=afterok:$sj --kill-on-invalid-dep=yes --cpus-per-task=8 --mem=4G -- trim "$m" "$s")
        if [ "$m" = trimmomatic ]; then
            o1=$OUT/trim/${m}_c8/$s.paired.trim_1.fastq.gz; o2=$OUT/trim/${m}_c8/$s.paired.trim_2.fastq.gz
        else
            o1=$OUT/trim/${m}_c8/${s}_1.trim.fastq.gz; o2=$OUT/trim/${m}_c8/${s}_2.trim.fastq.gz
        fi
        sub --dependency=afterok:$tj --kill-on-invalid-dep=yes -- map "${m}_$s" "$o1" "$o2" > /dev/null
    done
    # thread scaling of the chosen tool: cutadapt nt15 and Trimmomatic at 4 cpus as well
    sub --dependency=afterok:$sj --kill-on-invalid-dep=yes --cpus-per-task=4 --mem=4G -- trim nt15 "$s" > /dev/null
    sub --dependency=afterok:$sj --kill-on-invalid-dep=yes --cpus-per-task=4 --mem=4G -- trim trimmomatic "$s" > /dev/null
done
cat "$J"
