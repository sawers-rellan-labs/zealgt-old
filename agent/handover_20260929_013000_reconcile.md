# Handover: reconcile (--max_libraries guard, docs, run-name fix, strict cache test), branch `simplify`, 2026-09-29 01:30

Base: a12e2b2 (+ Phase D 864c7ce / 54f4c3a landed meanwhile). Not pushed; no CodeRabbit; no hazel runs.

## Commits
- `d49edef` --max_libraries as a run guard instead of the admission semaphore
- `0fc7397` Provenance record without workflow.runName; cache test R2 strict (every task CACHED)
- `8572a25` Docs reconciled (PLAN / REQUIREMENTS / usage / output / CHANGELOG / .nf-core.yml / two skills)
- this handover (`git add -f`)

## 1. --max_libraries (coordinator decision)
- `zgCheckCheckpointBound(libs)` (utils_nfcore_zealgt_pipeline, called first in `zgCheckDemuxRequest`, i.e. read_demultiplexing
  only): `zgCheckpointLibraries()` = sub-directories of `--fastq_checkpoint` (not `.*`, `subsample_<N>`, `checkpoint_stub*`: other
  checkpoint roots); refuse when |requested ∪ those| > N. The error message lists the checkpoint libraries not requested,
  each with `<dir>/cleanup_status.tsv` (or "no cleanup_status.tsv yet"), says removal only with the user's consent, and suggests
  fewer libraries / cleanup with consent / a larger N. A requested library that already has a checkpoint dir (-resume,
  --force_demux) counts once.
- Removed: `zgLibraryGate` / `zgAdmitLibrary` / `zgReleaseLibrary` and their wiring in workflows/cram.nf (the `gate`, the
  `ch_lib_crams.subscribe`). DEMUX: no maxForks (unchanged). read_alignment: not bounded.
- Comments/descriptions: conf/modules.config (DEMUX), modules/local/demux/main.nf header (outside script:, not hashed),
  nextflow.config, nextflow_schema.json description, conf/hazel.config header.
- tests/default.nf.test: the old N=1 ordering test replaced by (a) refusal: LIBX requested, a `checkpoint_stub/LIBZ/` with
  cleanup_status.tsv, N=1 -> failed, 0 tasks, stdout names LIBZ and its tsv; (b) LIBX,LIBY with N=2: 42 tasks, both samplesheets,
  LIBY's DEMUX task ids < every LIBX ALIGN_MARKDUP id (concurrent). No snapshot changes (these tests have none).

## 2. Docs (Phase C's 7 spots)
1. PLAN §3 paragraph: param name/default, `--libraries A,B`, subsample/stub guards, other-session and --max_libraries refusals. Done.
2. Schema file named, column list summarised to match `zgCheckpointColumns` (full list in usage.md). Done.
3. Verified = CRAM + .crai + CRAM 3 EOF, unverified -> error: matches code (zgCramState). Kept.
4. cleanup_status.tsv columns + log lines: written exactly as the code writes them (`# checkpoint <dir>: removable (N files, X GB)
   — remove only with the user's consent` / `keep: k of n CRAMs missing`; N = FASTQs). Done.
5. Store outputs: cram, cram_import, demux_qc, registry (+ provenance); step-4 marked "genotype workflow, not built yet". Done.
6. Cache test: described as built (operator script; deviation recorded in `.nf-core.yml` comment + docs/usage.md table) + first finding.
7. "stage-1 task dirs can be cleaned once the samplesheet exists" was WRONG for the chained run (stage 2 reads TRIMMOMATIC's work/
   files, not the checkpoint): corrected to "only after the run has ended" (a -resume of that session would then redo stage 1;
   cleaning frees only the demux FASTQs while the checkpoint holds the hardlinked pairs).
- PLAN §5 rule 3 rewritten for the guard semantics and "no maxForks"; rule 6 and §2 principle 6: conda envs STAY on
  /share/maize/frodrig4/conda/zealgt (never moved, rebuilt or deleted).
- **TRIMMOMATIC reports decision: accepted in the checkpoint** (not restored to `<outdir>/trimmomatic/`): a second publishDir with
  `meta` in its path breaks `nextflow config -o json` / nf-core lint (Phase B's experiment); MultiQC in outdir carries the numbers;
  cleanup counts only FASTQs, so the reports can be kept when the FASTQs are removed. Recorded in PLAN §3, usage.md deviations,
  output.md, CHANGELOG, nfcore-compliance skill. Not re-tested whether a saveAs-only variant would pass lint (open point below).
- Also: hazel-debug-loop skill "Durable outputs: storeDir" corrected; nfcore-compliance deviation list (no "storeDir store").

## 3. Extra item (coordinator, mid-task): run_name + strict cache test
- `zgRunSettings()` no longer has `run_name` (comment explains: hashed PROVENANCE input). docs/output.md, CHANGELOG (Fixed), PLAN §6.
- `tests/cache/cache_report.py`: the R2 run-name exception is gone; any non-CACHED R2 task is a FAIL with its changed components.
- `scripts/test_cache.sh local` on 0fc7397: **RESULT: PASSED**, R2 24 of 24 CACHED, R3 stage 1 10/10 cached + ALIGN_MARKDUP 3/3
  re-executed (script component only), R4 13 tasks stage 2 only. Summary `agent/cachetest/20260928_122529/summary.txt`, console
  `agent/20260929_004500_test_cache_local.txt`. (The checkout had uncommitted docs at the time: the script warned; docs only.)
- Guard vs test_cache.sh: no change needed. R1–R3 request one library (LIBX local / 1A hazel) on a checkpoint root holding at most
  that library (R2/R3 resume the same session -> union = 1 <= 4); preflight uses its own fresh checkpoint_stub; R4 is read_alignment
  (not bounded). Hazel mode: checkpoint root is `.../checkpoint/subsample_1000000`, its sub-dirs are libraries (1A only).
- Phase D handover's open point 1 (PROVENANCE reruns) is resolved; open point 3 (concurrent guard edits) checked as above. Points 2
  (hazel preflight untested), 4 (cleanup of agent/cachetest/* and the hazel scratch needs consent) remain.

## Checks (logs in agent/)
- `scripts/run_checks.sh` full, final code: lint 280 passed / 10 warnings / 0 failed; schema lint ok; nextflow lint 43 files no
  errors (6 pre-existing warnings); check_ext_args ok; nf-test 18/18; check_resources 24 rows 0 problems ->
  `20260929_005500_run_checks.txt` (first pass before the run-name change: `20260929_002000_run_checks.txt`).
- Local runs (`agent/20260929_000500_local_runs_reconcile.sh [stub|real|all]`, `ZG_RUN=<dir>`):
  stub (final code, `20260929_010000_local_runs_final.txt`): read_demultiplexing 24 tasks, read_alignment 13, markdup_import 9,
  refusal LIBY with LIBX checkpoint N=1 (0 tasks, LIBX + its cleanup_status.tsv named), refusal LIBX,LIBY N=1 on empty checkpoint,
  LIBX,LIBY N=2 SUCCESS 42 tasks. Real (final code, `20260929_011000_local_runs_real.txt`): chained 24 tasks SUCCESS, cleanup
  "removable (6 files)", provenance without run_name; LIBX,LIBY N=2 real 42 tasks SUCCESS (fixture sheet
  `agent/20260928_161500_samples_two_libs.csv`). The real part of that log's "all" run (`20260929_010000_...`) failed only because
  the script leaked the stub PATH (stub samtools) into the real part; fixed (P0) and rerun.

## Open points
- `--max_libraries` counts checkpoint dirs only, not leftover work/ of earlier runs (documented in PLAN §5 rule 3). An empty or
  partial checkpoint dir of a failed run also counts (conservative); the user removes it.
- A library with a checkpoint dir but no samplesheet (failed stage 1) shows "no cleanup_status.tsv yet" if no stage-2 run ended.
- Trim reports: if they must be in `<outdir>`, try a single publishDir map whose `saveAs` routes by file name (path without
  `meta`) — untested.
- Hazel Gate 0 note from Phase B still applies (stub checkpoint on /share, same GPFS fileset as work/).
- Shell-rule slips: one heredoc (python edit script written via `cat <<EOF` in the terminal) and one `cd && sed -i && grep`
  chain; no other effect. Scratch left for the user: `agent/20260929_000500_localrun`, `agent/20260929_010000_localrun`,
  `agent/20260929_011000_localrun`, `agent/cachetest/20260928_122529` (removal only with consent).
