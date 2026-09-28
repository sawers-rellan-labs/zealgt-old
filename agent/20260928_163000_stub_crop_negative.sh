#!/usr/bin/env bash
# Negative stub checks: crop 12/0 refused; sheet without crop columns refused.
A=/Users/fvrodriguez/repos/zealgt/agent; R=/Users/fvrodriguez/repos/zealgt; RUN=$A/20260928_161000_localrun_stub_entries
export PATH="$A/bin:$A/stubbin:$PATH" NXF_VER=26.04.6 NXF_ANSI_LOG=false
cd "$RUN" || exit 1
sed "2s/,0,0$/,12,0/" fastq.csv > fastq_crop.csv
cut -d, -f1-3 fastq.csv > fastq_nocrop.csv
for s in fastq_crop fastq_nocrop; do echo "== $s"; nextflow run "$R" -profile stub -stub --samples "$RUN/samples.csv" --fasta "$R/tests/fixtures/ref/tiny.fa" --entry read_trimming --input "$RUN/$s.csv" --outdir "$RUN/results_$s" 2>&1 | grep -iE "crop|error|SUCCESS" | head -5; done
