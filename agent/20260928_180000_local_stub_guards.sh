#!/usr/bin/env bash
# Local -stub checks of the run guards and the stored-sample skip after the refactor (reuses the store of
# agent/20260928_175500_local_stub_runs.sh demux): 1) rerun -> LIBX registered -> refused; 2) --force_demux LIBX -> no
# ALIGN_MARKDUP (all CRAMs stored); 3) --subsample 100 without a subsample store -> refused; 4) --subsample 100 with
# --store .../store_stub/subsample_100 -> runs; 5) --force_demux LIBY (not requested) -> refused; 6) --max_libraries 0 -> schema.
A=/Users/fvrodriguez/repos/zealgt/agent
R=/Users/fvrodriguez/repos/zealgt
export PATH="$A/bin:$A/stubbin:$PATH" NXF_VER=26.04.6 NXF_ANSI_LOG=false
RUN=$A/20260928_175500_localrun_stub; cd "$RUN" || exit 1
f() { grep -E "ERROR|refus|SUCCESS|FAILED|\[PROCESS|already in|needs a store|must|not in --libraries|max_libraries" | sed 's/^/    /' | head -30; }
echo "== 1 rerun (registered)"; nextflow run "$R" -profile test,stub -stub --outdir "$RUN/results_demux" 2>&1 | f
echo "== 2 --force_demux LIBX (stored skip)"; nextflow run "$R" -profile test,stub -stub --force_demux LIBX --outdir "$RUN/results_demux" 2>&1 | f
echo "== 3 --subsample 100, default stub store"; nextflow run "$R" -profile test,stub -stub --subsample 100 --outdir "$RUN/results_sub" 2>&1 | f
echo "== 4 --subsample 100, subsample store"; nextflow run "$R" -profile test,stub -stub --subsample 100 --store "$RUN/results_sub/store_stub/subsample_100" --outdir "$RUN/results_sub" 2>&1 | f
echo "== 5 --force_demux LIBY"; nextflow run "$R" -profile test,stub -stub --force_demux LIBY --outdir "$RUN/results_x" 2>&1 | f
echo "== 6 --max_libraries 0"; nextflow run "$R" -profile test,stub -stub --max_libraries 0 --outdir "$RUN/results_x" 2>&1 | f
echo "== 7 non-stub store outside store_stub with -stub"; nextflow run "$R" -profile test -stub --outdir "$RUN/results_x" 2>&1 | f
