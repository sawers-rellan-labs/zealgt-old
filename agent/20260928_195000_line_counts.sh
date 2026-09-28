#!/usr/bin/env bash
# Line counts of the pipeline code before (68e1c41) and after (HEAD) the refactor.
cd /Users/fvrodriguez/repos/zealgt || exit 1
count() { git show "$1:$2" 2>/dev/null | wc -l | tr -d ' '; }
printf '%-62s %6s %6s\n' file before after
for f in main.nf workflows/cram.nf subworkflows/local/utils_nfcore_zealgt_pipeline/main.nf \
         subworkflows/local/read_demultiplexing/main.nf subworkflows/local/read_trimming/main.nf \
         subworkflows/local/read_alignment/main.nf subworkflows/local/cram_import/main.nf subworkflows/local/cram_qc_provenance/main.nf \
         modules/local/demux/main.nf modules/local/demux_qc/main.nf modules/local/align_markdup/main.nf \
         modules/local/markdup_import/main.nf modules/local/provenance/main.nf modules/local/registry/main.nf \
         modules/local/demux_qc/resources/usr/bin/demux_qc.py modules/local/demux_qc/templates/summarize_demux.py \
         modules/local/registry/resources/usr/bin/registry.py modules/local/registry/templates/write_registry.py \
         modules/local/provenance/resources/usr/bin/provenance.py modules/local/provenance/templates/write_provenance.py \
         conf/modules.config nextflow.config nextflow_schema.json assets/schema_input.json assets/schema_samples.json assets/schema_import.json \
         docs/usage.md docs/output.md; do
    printf '%-62s %6s %6s\n' "$f" "$(count 68e1c41 "$f")" "$(count HEAD "$f")"
done
printf '\nlocal .nf code total (main.nf, workflows/cram.nf, subworkflows/local, modules/local main.nf): before %s after %s\n' \
    "$(git show 68e1c41:main.nf 68e1c41:workflows/cram.nf $(git ls-tree -r --name-only 68e1c41 subworkflows/local modules/local | grep 'main.nf$' | sed 's/^/68e1c41:/') | wc -l | tr -d ' ')" \
    "$(git show HEAD:main.nf HEAD:workflows/cram.nf $(git ls-tree -r --name-only HEAD subworkflows/local modules/local | grep 'main.nf$' | sed 's/^/HEAD:/') | wc -l | tr -d ' ')"
printf 'nf-test files: before %s after %s; snapshots: before %s after %s\n' \
    "$(git ls-tree -r --name-only 68e1c41 modules/local subworkflows/local tests | grep -c '\.nf\.test$')" \
    "$(git ls-tree -r --name-only HEAD modules/local subworkflows/local tests | grep -c '\.nf\.test$')" \
    "$(git ls-tree -r --name-only 68e1c41 modules/local subworkflows/local tests | grep -c '\.snap$')" \
    "$(git ls-tree -r --name-only HEAD modules/local subworkflows/local tests | grep -c '\.snap$')"
