# Handover: Phase A (resources the standard nf-core way), branch `simplify`, 2026-09-28 13:15

Brief: `agent/20260928_090500_design_simplify.md` "Phase A" items 1-10. Coordinator message mid-phase: Gate 2 memory values
replace the placeholders (applied; see "ALIGN_MARKDUP memory" below). Not pushed.

## Commits (on `simplify`, base bf2b6af)
- `6d28e19` Resources the standard nf-core way: drop the Slurm resource helper, Gate 2 memory for ALIGN_MARKDUP / MARKDUP_IMPORT
- `ec403a1` Checks: no task.* in ext.args closures, resolved hazel resources per process; drop normal.config's dead TRIMMOMATIC override
- `82a551f` Head job: REPO from ZG_REPO, full commit at the top, timestamp on every nextflow line
- (this handover, committed with `git add -f`)

## What changed, file by file
- `bin/export_slurm_resources.sh`: `git rm` (bin/ is now empty; nf-test.config's `bin/*` trigger left as template).
- `modules/local/demux/main.nf`: no `source`; `cutadapt -j ${task.cpus}`; the one bash `#` comment moved to the Groovy header.
- `modules/local/merge_lanes/main.nf`: no `source`; `${task.cpus}` files at a time.
- `modules/local/align_markdup/main.nf`: no `source`; minibwa `-t ${task.cpus}`, `samtools index -@ ${task.cpus}`; sort sizing in
  Groovy: `sort_threads = min(task.cpus, 4)`, `sort_mem_mb = max(768, floor((task.memory MB - align_mem_reserve_gb*1024) x
  align_sort_mem_share / sort_threads))`, logged to stderr (`align_markdup cpus=… memory_mb=… reserve_mb=… sort_share=…
  sort_threads=… sort_mem_mb=…`). zg_pipe_fail kept unchanged; its bash comments moved to the Groovy header.
- `modules/local/markdup_import/main.nf`: same bounded-share rule with its own reserve `params.import_mem_reserve_gb` (2 GB)
  and the shared `params.align_sort_mem_share`; logged to stderr; zg_pipe_fail kept; bash comments moved to Groovy.
- `modules/nf-core/{fastqc,samtools/stats,picard/collectwgsmetrics}/main.nf`: reverse-applied their resource-only diffs
  (`patch -R`, `agent/20260928_100500_revert_resource_patches.sh`; old diffs kept as `agent/20260928_100500_*.diff.prev`),
  `.diff` files `git rm`'d, `patch` keys removed from `modules.json`. nf-core lint confirms they match upstream.
- `modules/nf-core/trimmomatic/{main.nf,trimmomatic.diff}`: resource lines removed (upstream `-threads $task.cpus`, no `-Xmx`);
  diff regenerated with `nf-core modules patch trimmomatic` (old diff: `agent/20260928_101500_trimmomatic.diff.prev`). Only the
  functional patch remains (adapters input, no `-trimlog`, optional `trim_log`, meta.yml, tests).
- `conf/hazel.config`: `process.beforeScript = "mkdir -p '/share/maize/frodrig4/nf_work/${params.run_id ?: 'RUN_ID_NOT_SET'}/tmp'"`
  (see decision 1); comments rewritten (no helper); TRIMMOMATIC note (bioconda default heap 1 GB, peak 0.17-0.44 GB; FastQC /
  Picard heap from task.memory upstream); ALIGN_MARKDUP `memory = { params.align_memory_gb.toString().toInteger().GB *
  task.attempt }` (bc1 24 / other 28 GB split dropped, reason in the comment); perCpuMemAllocation comment.
- `conf/normal.config`: dead `withName: 'TRIMMOMATIC' { time = 12.h }` block + stale comment removed; comment on why one selector.
- `conf/local.config`, `conf/test.config`: `ZG_*` env blocks gone; test.config `withName: 'DEMUX' { cpus = 1 }` (macOS cutadapt).
- `nextflow.config` + `nextflow_schema.json` (new hidden group `align_resource_options`, "Memory tuning options"; integer-or-
  digit-string like `subsample`, since CLI values arrive as strings): `align_memory_gb` 24, `align_mem_reserve_gb` 16,
  `align_sort_mem_share` 0.75, `import_mem_reserve_gb` 2.
- `scripts/check_ext_args.py` (new): task.* inside `ext.args*` closures → `file:line` + exit 1. Tested on
  `agent/20260928_104500_ext_args_violation.config` (2 findings incl. a multi-line closure; comment/plain-string/cpus cases
  ignored); conf/*.config passes.
- `scripts/check_resources.sh` + `tests/expected_resources.tsv` (new): see brief item 6; details in decision 2.
- `scripts/run_checks.sh`: ext.args step (also `--quick`), check_resources step (full mode).
- `scripts/submit_head_job.sbatch`: `REPO="${ZG_REPO:-/rsstu/users/r/rrellan/BZea/ZEAL/zealgt}"`, prints REPO and full
  `git rev-parse HEAD` first, nextflow piped through `awk '{ print strftime("%F %T"), $0; fflush() }'`, exits with
  `${PIPESTATUS[0]}` (set +e around the pipe; set -eo pipefail would otherwise end the script first).
- `.nf-core.yml`, `docs/usage.md` (deviation row "Resources read from Slurm" removed; profiles paragraph on resources, the
  check, the head-job log), `docs/CONTRIBUTING.md` (checks list, hash hygiene), `.claude/skills/hazel-debug-loop/SKILL.md`,
  `.claude/skills/nfcore-compliance/SKILL.md`: no helper mentions left (`git grep` clean outside agent/, PLAN, REQUIREMENTS).

## Checks run (all on the final tree)
- `scripts/run_checks.sh` full: green — nf-core lint 275 passed / 10 warnings (pre-existing TODO / meta_include ones) / 0
  failed; schema lint ok; nextflow lint 43 files, no errors; ext.args check ok; nf-test 14/14 stub tests passed, no snapshot
  changes; check_resources 24 rows, 0 problems. Log `agent/20260928_120000_run_checks_final.txt` (also `_full1.txt`).
- check_resources alone: `agent/20260928_112000_check_resources_new2.txt` (pass). Precedence-loss demo
  (`agent/20260928_114500_demo_precedence_loss.sh`): HEAD's old normal.config vs a table with the old intent (TRIMMOMATIC normal
  12 h) → `MISMATCH normal TRIMMOMATIC expected … 12h …, got … 4h …`, exit 1 (`agent/20260928_112000_check_resources_demo_old.txt`);
  new normal.config restored (cmp ok) and passes.
- nf-core TRIMMOMATIC module's own nf-test with real trimmomatic 0.39: 4/4 passed, snapshot unchanged
  (`agent/20260928_121500_nftest_trimmomatic.txt`). Note: the old harness (main checkout `agent/20260929_002000_nftest_nfcore.config`)
  loads conf/modules.config, whose TRIMMOMATIC ext.args made upstream's "No Adaptors" test (expects failure) succeed; it only
  "passed" before because the helper failed outside Slurm. New harness `agent/20260928_122000_nftest_nfcore*.config` nulls
  that ext.args. FASTQC / SAMTOOLS_STATS / PICARD upstream tests not rerun (unpatched upstream; laptop samtools 1.23 ≠ pin).
- Local stub runs (`agent/20260928_123000_local_runs.sh stub`): read_demultiplexing SUCCESS 24 tasks, markdup_import SUCCESS 9.
- Local real run on the fixtures (`… real`, laptop tools, `agent/20260928_123000_local_real.config`): SUCCESS 24 tasks; demux
  summary 940 in / 900 assigned; 3 CRAMs × 600 records; `.command.sh` shows `-j 1`, `-threads 2`, `-Xmx3276M` (Picard 0.8 × 4 GB),
  `samtools sort -@ 2 -m 768M`. Compared with the main checkout's helper-based run 20260929_022000: alignments identical
  (md5 of `samtools view`), demux summary identical, markdup.stats differ only in the tmp path of the COMMAND line
  (`agent/20260928_124500_compare_real_runs.sh`). Logs under `agent/20260928_123000_localrun/`.
- Head-job pipe: `agent/20260928_125000_test_head_pipe.sh` (bash -n ok; gawk strftime timestamps; rc 3 of the producer kept).
  hazel login node: `awk` → `/usr/bin/gawk`, GNU Awk 5.1.0, RHEL 9.8.

## Decisions
1. **TMPDIR:** `.command.run` runs `beforeScript` *before* it exports the `env` scope (seen in a generated wrapper), so the
   brief's `'mkdir -p "$TMPDIR"'` would create the node's default temp dir, not the run's. beforeScript spells the path out
   (same expression as env.TMPDIR); check_resources.sh verifies via `nextflow config -flat -profile hazel,normal` that
   beforeScript == `mkdir -p '<env.TMPDIR>'`. Nothing else relied on the helper (ZG_JAVA_MEM_MB users were the reverted
   patches; build_envs.sh's ZG_* vars are unrelated).
2. **check_resources.sh uses the real profiles** (`-profile hazel,normal|short -stub`) plus an override `-c` config (local
   executor 64 cpu / 1 TB, conda off, work/TMPDIR/beforeScript/outdir/store_stub under the scratch dir, trace fields incl. time
   and queue) instead of a check config that `includeConfig`s hazel + normal: same selector order as production. Both entries
   run (markdup_import on touch-file CRAMs) so MARKDUP_IMPORT and the import QC are covered. Each observed process needs a row
   and every row must be observed (a new process forces a table update). DEMUX's 6 cpus reflect the bc1 fixture only.
   `--expected <tsv>` overrides the table; `ZG_RES_SCRATCH` the scratch dir (default `agent/check_resources/<time>`).
3. **Gate 2 memory (coordinator's values):** `align_memory_gb` 24, `align_mem_reserve_gb` 16, `align_sort_mem_share` 0.75
   (replaces the brief's `align_sort_rss_factor`); MARKDUP_IMPORT gets its own `import_mem_reserve_gb` 2 (no minibwa index;
   streaming stages) and shares `align_sort_mem_share` (same samtools sort behaviour) → 7.5 GB sort at the 12 GB first attempt
   (was 6 GB), ≥ 3.7 GB for the rest. Params referenced in the scripts are hashed by value (a re-tune reruns ALIGN_MARKDUP /
   MARKDUP_IMPORT, and changing the shared share param reruns both). No PLACEHOLDER markers remain.
4. Schema types for the new params are integer-or-digit-string / number-or-string (as `subsample`): CLI values arrive as strings.
5. TRIMMOMATIC: upstream has no `-Xmx` → bioconda wrapper default; kept (measured peak 0.17-0.44 GB), noted in hazel.config.
6. Three focused commits; docs in commit 1 already mention the check scripts added in commit 2.

## Open points
- **Merge with main:** main is applying an equivalent bash fix on `$ZG_MEM_MB` (ALIGN_MARKDUP sort -m); when merging
  origin/main into `simplify`, resolve `modules/local/align_markdup/main.nf` (and any hazel.config memory lines) in favour of the
  task.memory version here.
- The ALIGN_MARKDUP memory values live in: `nextflow.config` params block (`align_memory_gb`, `align_mem_reserve_gb`,
  `align_sort_mem_share`, `import_mem_reserve_gb`), their defaults in `nextflow_schema.json` group `align_resource_options`
  (lint checks both agree), the formula in `modules/local/align_markdup/main.nf` / `modules/local/markdup_import/main.nf`
  script blocks, the first-attempt use in `conf/hazel.config` `withName: 'ALIGN_MARKDUP'`, and the expected 24 GB in
  `tests/expected_resources.tsv` (update it with any change of align_memory_gb).
- PLAN / REQUIREMENTS still describe the helper (Phase C). docs/usage.md "storeDir …" rows untouched (Phase B/C).
- All task hashes of DEMUX, MERGE_LANES, TRIMMOMATIC, FASTQC, ALIGN_MARKDUP, MARKDUP_IMPORT, SAMTOOLS_STATS, PICARD change
  with these script edits (expected; no resume across this commit).
- `/usr/bin/awk` is gawk on the login node; compute nodes assumed to share the RHEL 9 image (first head job's timestamps confirm).
- hazel,local: resourceLimits 4 cpu / 16 GB now caps what one task uses (was ZG_CPUS 2 / ZG_MEM_MB 6144); adjust to the salloc.
- Shell-rule slip: `agent/20260928_100000_edit_align_markdup.py` was written with a terminal heredoc (then run from the file);
  all later scripts were written with the editor.
