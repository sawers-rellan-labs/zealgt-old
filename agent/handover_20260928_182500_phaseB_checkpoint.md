# Handover: Phase B (FASTQ checkpoint, two stages, skip-if-stored instead of storeDir), branch `simplify`, 2026-09-28 18:25

Brief: `agent/20260928_090500_design_simplify.md` "Phase B" + prompt item 2. Mid-phase coordinator items, done: (a) `--max_libraries`
as a library admission gate (PLAN §5 rule 3); (b) Gate 2 relaunch memory values (align_memory_gb 32, align_mem_reserve_gb 20).
Not pushed; origin/main not merged; CodeRabbit not run.

## Commits (on `simplify`, after Phase C's 2844ee1)
- `020cab5` ALIGN_MARKDUP memory from the Gate 2 relaunch: 32 GB first attempt, reserve 20 GB (share 0.75)
- `53b0fbb` CRAM workflow in two stages with a FASTQ checkpoint; store by publishDir + skip-if-stored; library admission gate
- `09925db` docs/usage.md, docs/output.md
- (this handover, `git add -f`)

## Design as built

**Params** (nextflow.config + nextflow_schema.json): `fastq_checkpoint` (default `/share/maize/frodrig4/fastq_checkpoint`,
group "Store and reference"); `entry` enum + `read_alignment`; `libraries` used by both stage-2 entries; `max_libraries`
default **4** (was 1; PLAN §5 rule 3 as the Phase C writer left it); `align_memory_gb` 32, `align_mem_reserve_gb` 20.
No `skip_alignment` param (not asked; stage 1 alone = run read_demultiplexing and let stage 2 fail/stop; open point).

**Entries** (`--workflow cram`):
- `read_demultiplexing` (default): DEMUX per lane -> MERGE_LANES -> DEMUX_QC -> TRIMMOMATIC (-> checkpoint) -> FASTQC, then
  stage 2 in the same run on `READ_TRIMMING.out.reads` (never the published files). Every sample is trimmed, also those
  whose CRAM is already stored (so the checkpoint always holds the whole library; stage 2 still skips the stored ones).
- `read_alignment`: `--libraries A,B` -> `<ckpt>/<lib>/samplesheet.csv` via `samplesheetToList` + `assets/schema_checkpoint.json`
  in PIPELINE_INITIALISATION (`zgAlignmentInputs`); ALIGN_MARKDUP -> SAMTOOLS_STATS + PICARD -> PROVENANCE -> REGISTRY. No registry
  guard, no max_libraries gate (nothing is demultiplexed). Missing `<store>/demux_qc/<lib>.tsv` -> warning, library aligned
  but not registered (deviation from the brief's "needs": a fresh store, as the Phase D R3/R4 plan uses, must still align).
- `markdup_import`: unchanged in function (publishDir + skip + EOF check).

**Checkpoint samplesheet** columns (file order, `zgCheckpointColumns`): sample, library, fastq_1, fastq_2, source, role, donor,
taxon, read_group, read_structure, layout, barcode_r1, barcode_r2, demux_args, trim_illuminaclip, trim_args, trim_adapters,
raw_location, raw_files_r1, raw_files_r2, tar_members_r1, tar_members_r2 (`;`-joined), subsample, stage1_run_id,
stage1_session_id, stage1_code_version, stage1_tool_versions (`tool=version;...`). Added to the brief's list: `layout` (origin
field) and `stage1_tool_versions` (so the provenance JSON of stage 2 alone equals the chained one). fastq paths absolute
(`file(params.fastq_checkpoint).toAbsolutePath().normalize()/<lib>/<sample>.paired.trim_{1,2}.fastq.gz`). Rows are built at
init (`zgCheckpointRow`, all strings except integer subsample, the same types when read back: nf-schema gives `[]` for empty
cells, Path for file-path cells -> `zgCell`), validated for CSV-ability at init (`zgCsvLine`: nf-schema reads `"..."`-quoted
cells with commas, e.g. the PU list in read_group, but NOT doubled quotes -> a quote/newline in a value is an error), and
written by `zgWriteCheckpointSheet` (temp file + atomic move) from a `subscribe` once all samples of the library are trimmed.
Meta: `zgCheckpointMeta(row)` = [id, sample, library, source, role, donor, taxon, single_end:false, qc_group:library] (same as
before). Provenance: `zgCheckpointRecord(settings, row)` for both entries; the chained run fills `origin.stage1_tool_versions`
via `zgWithStage1Tools` from the same string. Record changes: `session_tool_versions` (top level, incl. FASTQC) replaced by
`origin.stage1_tool_versions` (DEMUX + TRIMMOMATIC tools only), new `origin.fastq_checkpoint`, `origin.stage1_*`.
Stage-1 tool versions: `zgStage1Tools()` = cutadapt, pigz, tar, trimmomatic; taken with `unique().take(4)` as soon as each
reported once (not `toList()` of the whole session: with the gate a library's samplesheet would otherwise wait for later
libraries, and was never written when stage 2 failed — seen in the failure test). A tool added to DEMUX/TRIMMOMATIC must be
added to `zgStage1Tools`.

**Skip rules** (workflow logic; utils functions): CRAM per sample `zgCramState(dir,id)`: `stored` = CRAM + .crai + last 38
bytes == htslib CRAM 3 EOF (`zgCramEofOk`, verified against a samtools 1.23 CRAM); `absent` = none of the sample's store files;
`broken` = anything else (unverified CRAM, or leftover .stats/.provenance.json/... without CRAM) -> `zgCheckStoredCrams` errors
at init for every entry, listing the files to check/remove (they could not be overwritten anyway). DEMUX_QC per library:
`zgStoredDemuxQc` (tsv present) -> READ_DEMULTIPLEXING's new `ch_stored_qc` input, stored tsv/summary emitted instead.
PROVENANCE per sample: `zgStoredQc` now includes `<id>.provenance.json`; CRAM_QC_PROVENANCE skips it and emits the stored one
(kept out of the MultiQC qc channel). REGISTRY per library: `zgIsRegistered`. Stub CRAMs (ALIGN_MARKDUP, MARKDUP_IMPORT) are
the 38-byte EOF block (printf), so stored stub CRAMs verify.

**Publish rules** (conf/modules.config): store outputs `mode: 'copy', overwrite: false, failOnError: true` for DEMUX_QC,
ALIGN_MARKDUP, SAMTOOLS_STATS/PICARD (both contexts), PROVENANCE (both), MARKDUP_IMPORT, REGISTRY. Measured: overwrite:false
silently keeps an existing target (no error even with failOnError). TRIMMOMATIC: ONE map to `${fastq_checkpoint}/${meta.library}`,
`mode: 'link'`, pattern trimmed pairs + `.summary` + `_out.log`, failOnError. Deviation: the brief implied a second publishDir;
a publishDir *list* whose closures use `meta` breaks `nextflow config -o json` (nf-core lint "No such variable: meta";
`agent/20260928_171000_pubdir_json_variants.sh`: every closure in a list is evaluated, a single map is not), so the trim
reports moved from `<outdir>/trimmomatic/` into the checkpoint (MultiQC still gets them). Checkpoint overwrite = Nextflow default
(true in a new session, e.g. --force_demux relinks; false on -resume). DEMUX `maxForks 3` removed (gate).

**Cleanup report** (`zgCheckpointCleanupReport`, from `workflow.onComplete` in PIPELINE_COMPLETION, success or failure, entries
read_demultiplexing / read_alignment): per library reads `<ckpt>/<lib>/samplesheet.csv` (nf-schema), writes
`<ckpt>/<lib>/cleanup_status.tsv`: header `sample cram cram_bytes verified fastq_1 fastq_1_bytes fastq_2 fastq_2_bytes`
(tab), one row per sample (fastq = file names), last line `# checkpoint <dir>: removable (N files, X GB) — remove only with the
user's consent` or `# checkpoint <dir>: keep: k of n CRAMs missing`; same line in the log. No samplesheet -> log `keep: no
samplesheet.csv`. Facts behind it (26.04.6): `params`/`projectDir` are null inside onComplete (all values captured before);
`Session.destroy` shuts the finalize + publish pools (waiting for transfers) before `shutdown0` runs onComplete
(`agent/20260928_141000_javap_session_destroy.sh`), so the report sees finished copies on a normal end; an aborted copy fails
the EOF check (conservative). N files counts the FASTQs only.

**Guards** (zgRunGuards / zgCheckDemuxRequest): `zgCheckOutputRoot` for `--store` and (stage-2 entries) `--fastq_checkpoint`:
subsample_<N> naming both ways, stub runs need a `store_stub*` / `checkpoint_stub*` component outside the production root
(`/share/maize/frodrig4/fastq_checkpoint`). `--libraries` required for both stage-2 entries. read_demultiplexing refuses a
library whose checkpoint samplesheet has another `stage1_session_id` (use read_alignment, `-resume <session>`, or
`--force_demux`). read_alignment: no samplesheet -> error; row library / subsample mismatch -> error. The old
`libs.size() > max_libraries` error is gone.

**Library admission** (coordinator item): `zgLibraryGate()` = fair `Semaphore(max_libraries)`; `ch_libraries.map {
zgAdmitLibrary(gate, it) }` feeds READ_DEMULTIPLEXING (blocks the (N+1)th library in that one operator); `ch_lib_crams` (all
CRAMs of a library, new + stored, out of stage 2) `.subscribe { zgReleaseLibrary }`. Why a semaphore: DSL2 has no channel
cycles; the dataflow pool is a fixed ThreadPoolExecutor of ncpus+1 threads (log: "poolSize: 11"; 2 on a 1-cpu head job), and
only this operator ever blocks, so >= 1 thread stays free. On a stopped run the blocked acquire is interrupted ->
`error("library X was not admitted ...")`; the run ends (tested, no hang). Order = `--libraries` order.

## File-by-file
- `assets/schema_checkpoint.json` (new): the samplesheet schema above (fastq file-path + exists + name pattern, uniqueEntries sample).
- `subworkflows/local/utils_nfcore_zealgt_pipeline/main.nf`: guards (`zgCheckOutputRoot`, checkpoint-session guard,
  `zgCheckpointSessions`), `zgDemuxInputs` builds rows/meta/records, new `zgAlignmentInputs`, checkpoint functions (columns,
  dir/sheet, zgCell, zgCheckpointRow, zgReadCheckpointSheet, zgCsvLine, zgWriteCheckpointSheet, zgCheckpointMeta,
  zgCheckpointRecord, zgStage1Tools, zgToolVersionsString, zgParseToolVersions, zgWithStage1Tools, zgCheckpointCleanupReport),
  gate (zgLibraryGate / zgAdmitLibrary / zgReleaseLibrary), store (zgCramEof, zgCramEofOk, zgSampleStoreFiles, zgCramState,
  zgIsStored, zgCheckStoredCrams, zgStoredQc + provenance.json, zgStoredDemuxQc, zgIsRegistered), `zgSplit`; emits
  `checkpoint` instead of `samples`; PIPELINE_COMPLETION runs the report.
- `workflows/cram.nf`: rewritten wiring (stage 1 branch, read_alignment branch, common stage 2, registry skip, gate).
- `main.nf`: `ch_checkpoint` replaces `ch_samples`; header.
- `subworkflows/local/read_demultiplexing/main.nf` (+ meta.yml, tests: new stored-demux-QC test), `cram_qc_provenance/main.nf`
  (+ meta.yml, test: stored provenance), `read_alignment`, `cram_import`, `read_trimming` (+ test: checkpoint links): comments,
  skip logic.
- Modules `align_markdup`, `markdup_import` (header comments outside the script; stub = EOF block), `demux_qc`, `provenance`,
  `registry` (header comments); all five meta.yml descriptions. Script blocks unchanged (hash of the real tasks unchanged
  by this commit except via the new memory params in ALIGN_MARKDUP).
- `conf/modules.config` (publish rules), `conf/stub.config` (`fastq_checkpoint = <outdir>/checkpoint_stub`), `conf/test.config`
  (`<outdir>/checkpoint_test`), `conf/hazel.config` (comments; memory comment), `nextflow.config`, `nextflow_schema.json`.
- `scripts/check_resources.sh`: `--fastq_checkpoint "$D/checkpoint_stub"`; `tests/expected_resources.tsv`: ALIGN_MARKDUP 32 GB
  (task list unchanged: no new process).
- `tests/default.nf.test` (+ snap): read_demultiplexing (checkpoint asserts), new read_alignment stub (hand-written 2-sample
  checkpoint + demux_qc tsv, 10 tasks, no stage-1 task), new two-library `--max_libraries 1` stub (42 tasks; LIBY's DEMUX task
  ids > all LIBX ALIGN_MARKDUP task ids, read from `$outputDir/../meta/trace.csv` — nf-test does not capture log.info), markdup_import.
  `tests/.nftignore`: checkpoint samplesheet / cleanup_status / fastq content.
- `docs/usage.md`, `docs/output.md`.

## Checks and logs (all under agent/)
- `scripts/run_checks.sh` full, final tree: nf-core lint 279 passed / 10 warnings (pre-existing) / 0 failed; schema lint ok;
  nextflow lint 43 files no errors; ext.args ok; nf-test 17/17; check_resources 24 rows 0 problems ->
  `20260928_170000_run_checks_full2.txt` (via `20260928_170000_run_checks_full.sh`).
- nf-test snapshot updates: `20260928_154000_nftest_update*.txt`, `_clean2.txt` (script `20260928_154000_nftest_update.sh [update|clean]`).
- Final local runs (fresh dirs `20260928_174500_localrun_final/`, log `20260928_174500_localrun_final.txt`): stub
  read_demultiplexing 24 tasks, stub read_alignment 13 (fresh store, that checkpoint), stub markdup_import 9; real1 chained 27
  tasks, checkpoint files have the TRIMMOMATIC work file's inode (links=2), samplesheet 3 rows, 3 CRAMs x 600 records with EOF,
  cleanup "removable (6 files, 0.00 GB)"; real2 read_alignment fresh store: only ALIGN_MARKDUP/STATS/PICARD/PROVENANCE x3 +
  MULTIQC; real3 same: only MULTIQC (all skipped as stored); real4 LX_2.cram cut by 100 bytes: refused at init, 0 tasks, lists
  LX_2's 8 files. Chained vs alone (`20260928_174500_compare_stage2.txt`): alignments identical (md5 of samtools view),
  provenance differs only in cram_bytes (header @PG/@SQ UR paths), entry, record time, run name, session, store_dir.
- Guards (stub, `20260928_153000_stub_guards_phaseB.txt`): other-session checkpoint refused; --force_demux passes; subsample
  naming; stub naming; read_alignment without sheet; subsample mismatch.
- Gate (`20260928_161500_gate_runs.sh all`, `20260928_161500_gate_all.txt`): stub max 1 -> LIBY's first DEMUX after LIBX's last
  ALIGN_MARKDUP (trace times), 42 tasks; max 2 -> both admitted at once; real max 1 -> same ordering, 42 tasks; failure
  (ALIGN_MARKDUP beforeScript exit 3, errorStrategy finish) -> run ends exit 1, LIBX samplesheet written ("keep: 3 of 3 CRAMs
  missing"). Two-library sheet: `20260928_161500_samples_two_libs.csv` (LIBY = 2 samples on LIBX's lanes).
- Experiments: `20260928_140000_exp_publish/` (onComplete + publish, overwrite:false, link inode, nf-schema quoting),
  `20260928_141000_javap_session_destroy.sh`, `20260928_160000_javap_dataflow_pool.sh`, `20260928_160500_javap_custompool.sh`,
  `20260928_171000_pubdir_json_variants.sh`.

## Local run commands (for the Phase D cache-test script)
From a launch dir; `A=/Users/fvrodriguez/repos/zealgt/agent`, `R=<checkout>`, `NXF_VER=26.04.6 NXF_ANSI_LOG=false`,
real tools `PATH=$A/bin:$A/localbin:$PATH` (+ brew samtools), stub `PATH=$A/bin:$A/stubbin:$PATH`;
real config `agent/20260928_123000_local_real.config` (conda off, local executor 2 cpu / 4 GB) — copy it into the scratch clone.
```
# R1 chained (store and checkpoint under the outdir: test.config store_test / checkpoint_test)
nextflow run $R -profile test -c $R/agent/20260928_123000_local_real.config --outdir $D/r1/results [-dump-hashes json]
# stage 2 alone against R1's checkpoint with a fresh store
nextflow run $R -profile test -c $R/agent/20260928_123000_local_real.config --entry read_alignment \
    --fastq_checkpoint $D/r1/results/checkpoint_test --store $D/r2/store --outdir $D/r2/results
# stubs
nextflow run $R -profile test,stub -stub --outdir $D/stub/results_demux
nextflow run $R -profile test,stub -stub --entry read_alignment --fastq_checkpoint $D/stub/results_demux/checkpoint_stub --outdir $D/stub/results_align
```
Notes for Phase D: `-resume <R1 session>` of read_demultiplexing is allowed by the checkpoint guard (same stage1_session_id);
a new-session read_demultiplexing onto an existing checkpoint (or registered store) is refused — use a fresh outdir/store or
the same session. R3 (fresh store, -resume) re-links the checkpoint files (overwrite false on resume: kept).

## Open points
- **Hazel Gate 0**: stub.config's `<outdir>/checkpoint_stub` is on /rsstu there; pass `--fastq_checkpoint
  /share/maize/frodrig4/nf_work/<run_id>/checkpoint_stub` (hardlinks cannot cross /share -> /rsstu). Also check that work/
  (`/share/maize/frodrig4/nf_work/...`) and `/share/maize/frodrig4/fastq_checkpoint` are in the same GPFS fileset (cross-fileset
  hardlinks fail; a failed link fails the run, it does not copy).
- **Gate vs disk**: the gate bounds libraries being processed, but Nextflow keeps every library's work/ for the whole run,
  so the run's work/ still grows with all requested libraries; a real bound on /share needs per-library cleanup of stage-1
  work dirs once the samplesheet exists (PLAN rule 4, user consent) or requests of <= N libraries. With N = 1 stage 1 of the
  next library waits for stage 2 of the previous one (no overlap).
- The gate relies on one blocking operator on Nextflow's fixed dataflow pool (verified on 26.04.6 only); re-check on upgrades
  (virtual-thread pools would be fine). log.info lines of the gate/skip appear run-together on the non-ANSI console (cosmetic).
- REGISTRY checks the staged (work) CRAMs; with async publishing the store copies can still be in flight when the registry
  entry is written (a killed head then leaves a registered library with a truncated CRAM, which the next run refuses with the
  EOF error). Acceptable? Alternative: register from onComplete.
- `write_provenance.py` docstring still says "tool versions of the steps run in this session" (not edited: it is hashed).
- No `--skip_alignment` (stage 1 only) option; add if wanted.
- `.summary`/`_out.log` now live in the checkpoint, not `<outdir>/trimmomatic/` (lint constraint above); PLAN/REQUIREMENTS
  wording on this (Phase C owner) may need a line. PLAN §5 rule 3 says "DEMUX maxForks = N x lanes": maxForks is now removed
  (the gate implies it) — Phase C/coordinator to align the sentence.
- Shell-rule slips: two chained one-liners (`cd && sed && bash` in the experiment dir and in agent/, and a `sed && grep` in the
  repo) and one empty heredoc; no other effect.
