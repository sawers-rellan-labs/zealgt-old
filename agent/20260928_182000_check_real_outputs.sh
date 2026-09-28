#!/usr/bin/env bash
# Checks of the real local run outputs (agent/20260928_180500_localrun_real2): demux QC, registry, provenance (template),
# read groups, duplicate flags, the import read-group decisions, and that no task script names the checkout path.
RUN=/Users/fvrodriguez/repos/zealgt/agent/20260928_180500_localrun_real2
R=/Users/fvrodriguez/repos/zealgt
FA=$R/tests/fixtures/ref/tiny.fa
S=$RUN/store
echo "## demux summary"; cat "$S/demux_qc/LIBX.summary.tsv"
echo "## demux per sample"; cat "$S/demux_qc/LIBX.tsv"
echo "## read_start LX_1 R1 pos 1-3"; awk -F'\t' '$2=="LX_1" && $3=="R1" && $5<=3' "$S/demux_qc/LIBX.read_start.tsv"
echo "## registry"; cat "$S/registry/LIBX.registry.tsv"
echo "## versions ymls"; cat "$S/demux_qc/LIBX.demux_qc.versions.yml" "$S/registry/LIBX.registry.versions.yml" "$S/cram/LX_1.align_markdup.versions.yml" "$S/cram_import/OLD_1.markdup_import.versions.yml"
echo "## provenance LX_1 keys + session tools + versions"; python3 -c "import json,sys; d=json.load(open('$S/cram/LX_1.provenance.json')); print(sorted(d)); print(d['session_tool_versions']); print(list(d['tool_versions_yml'])); print(d['cram_bytes'], d['read_group'])"
echo "## RG on every record / dup flags (LX_1)"; samtools view -T "$FA" "$S/cram/LX_1.cram" | awk '{n++; if ($0 ~ /\tRG:Z:LX_1/) rg++; if (and($2, 1024)) d++} END {print n" records, "rg" with RG:Z:LX_1, "d" duplicates"}'
echo "## import read groups"; for s in OLD_1 LX_2 OLD_3; do printf '%s: ' $s; grep source "$S/cram_import/$s.read_group.txt" | tr '\t' ' '; samtools view -H -T "$FA" "$S/cram_import/$s.cram" | grep '^@RG' | tr '\t' ' '; done
echo "## projectDir in task scripts (expect none besides inputs/staging)"; grep -l "$R" "$RUN"/work/*/*/.command.sh | head; echo "(end)"
echo "## multiqc reports"; ls "$RUN"/results_demux/multiqc "$RUN"/results_import/multiqc
