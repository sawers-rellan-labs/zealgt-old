# Handover: Phase D (cache test), branch `simplify`, 2026-09-29 00:05

Brief: `agent/20260928_090500_design_simplify.md` "Phase D". Commit `864c7ce` (plus this handover). Not pushed. Not run on hazel.

## Files (mine only)
- `scripts/test_cache.sh` — `local | hazel | report <scratch>`.
- `scripts/test_cache.sbatch` — head job for hazel mode. It works like submit_head_job.sbatch: ZG_REPO, REPO and the full commit
  printed at the top, the nextflow env on PATH, every line timestamped with gawk strftime, and the job exits with the script's status.
  Settings: 1 cpu, 8 GB, short QOS, 2 h. Log: `/share/maize/frodrig4/nf_work/zealgt_cachetest_<job>.log`.
- `tests/cache/local.config` — a copy of Phase B's local real config.
- `tests/cache/raise_local.config` and `raise_hazel.config` — R2 raises every resource. They use a `withName: '.*'` block and raise
  resourceLimits too.
- `tests/cache/preflight.config` — local executor with a 64 cpu / 1 TB pool.
- `tests/cache/edit_align_markdup.py` — the R3 edit. It changes `rmdir … || true` to `|| :`, and refuses to run unless that line
  occurs exactly once and sits inside the script: block.
- `tests/cache/cache_report.py` — the assertions and hash tables, written to `<scratch>/summary.txt`. It needs Python 3.6 or later.

## Design as built
- **Clone and launch dir.** The script clones the checkout's HEAD with `git clone` and sets `core.fileMode false`. It warns if the
  checkout has uncommitted tracked changes, because those are not tested. R1–R4 all run from one launch dir, `<S>/launch`, with
  `nextflow -log <S>/logs/<run>.nextflow.log` and `-with-trace <S>/traces/<run>.txt`. `<S>/run.config` holds the trace fields;
  on hazel it also sets TMPDIR and the matching beforeScript to `<S>/tmp`.
- **Store per run.** `--store` is always `<S>/store_live/<leaf>`, a symlink that `ln -sfn` re-points to an empty
  `<S>/stores/rN/<leaf>` before each run. The store path is part of the provenance record, which is an input of PROVENANCE, so this
  keeps R2 different from R1 in resources only. It also gives every run a fresh store: a stored CRAM would be skipped, not cached.
  The symlink works with publishDir and with the run guards, which resolve realpath, so the leaf name stays `subsample_1000000`.
- **Shared checkpoint.** All runs share `<S>/checkpoint/<leaf>`.
- **Preflight (my addition).** A `-stub` run with R2's exact profiles and configs, in its own launch dir. The report asserts that,
  for every process, R2's minimum cpus, memory and time are each above R1's maximum. Without this R2 could pass without testing
  anything. It already caught one: a first raise of `45.min` was below the 1 h that the base.config labels give R1.
- **R3 edit.** The edit is committed in the clone, as a fix would be. As a result code_version changes, and the evidence shows it
  reaches only REGISTRY, not stage 1.
- **R2 rule.** Every task must be CACHED. The one exception: a re-executed task is accepted only if every hash entry that changed
  is an input value that differs from R1's by the run name alone (R1's name, then R2's). Any other re-execution fails the test.
- **Hash matching.** A dump carries a task index, and its cache hash differs from the trace's work-dir hash, so tasks are matched
  across runs by (process, meta.id).

## Local result (PASSED): `agent/cachetest/20260928_121644/summary.txt`, console `agent/20260928_235500_test_cache_local2.txt`
- R1: 24 tasks. The preflight confirms every process was raised: cpus 1–2 to 3, memory 4 GB to 6 GB, time 1 h to 1 h 30 m.
- R2: 21 of 24 tasks CACHED, including every stage-1 task, ALIGN_MARKDUP, STATS, PICARD, REGISTRY and MULTIQC.
- R3: all 10 stage-1 tasks CACHED, and all 3 ALIGN_MARKDUP tasks re-executed. For ALIGN_MARKDUP the only changed hash component is
  the script source (diff `|| true` to `|| :`). Downstream, STATS, PICARD, PROVENANCE, REGISTRY and MULTIQC re-ran because they got
  new input paths; REGISTRY also got a new code_version.
- R4: 13 tasks, stage 2 only. There is no REGISTRY task, because `demux_qc` is absent from the fresh store (Phase B design).
- The first run, `agent/cachetest/20260928_121303` (console `…_local1.txt`), failed only on the preflight's time check. That led
  to the 90 min fix.

## Hazel command (coordinator; after the commit is on the hazel checkout, and not while another run uses it)
```
ssh hazel 'sbatch /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/test_cache.sbatch'
```
- To test another checkout: `ssh hazel 'ZG_REPO=<checkout> sbatch --export=ALL /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/test_cache.sbatch'`.
- Result: the log ends with `RESULT: PASSED|FAILED` and `zealgt_cachetest exit=<rc>`. The summary is at
  `/share/maize/frodrig4/nf_work/simplify_cachetest/<time>/summary.txt`.
- To re-run only the report: `bash scripts/test_cache.sh report <scratch>`. It is read-only and parses a few logs, but run it inside
  a job all the same.
- Run parameters: `-profile hazel,short --workflow cram --libraries 1A --subsample 1000000 --run_id simplify_cachetest`. R1–R3
  and the preflight add `--entry read_demultiplexing --force_demux 1A`; R4 adds `--entry read_alignment`, without force_demux.
  Store and checkpoint leaves are named `subsample_1000000` and sit under the scratch dir, never under ZEAL/store. The preflight
  uses `preflight/store_stub/…` and `preflight/checkpoint_stub/…`.
- Expected duration: about 1 h, from Gate 1 (76 tasks in 17.5 min) plus Picard's 6.5 min floor in R3 and R4, plus the stub
  preflight. If it does not fit in short's 2 h, resubmit with `--qos=normal --partition=compute --time=04:00:00`.

## Open points
1. **PROVENANCE re-runs on every `-resume`.** Its `record` input carries `workflow.runName`. It is cheap, but it means the provenance
   JSON of a CRAM that was cached from R1 names the resuming run. Should the record's run fields be those of the run that made the
   CRAM, or should run_name be dropped from the hashed record? The test tolerates exactly this case, and a strict "every task
   CACHED" would fail on it.
2. **Hazel preflight is untested.** It runs a stub with conda prefixes under a local executor (1 cpu head, queueSize 8). This follows
   check_resources.sh, but it has never run on hazel. It relies on the local-executor pool accepting the 12 cpu / 48 GB requests
   (preflight.config sets 64 / 1 TB).
3. **Concurrent guard edits.** The other writer is changing the guards (e.g. a "libraries on disk bounded" line in
   zgCheckDemuxRequest). A new guard may refuse the R2/R3 `-resume` or R4 parameters. If so, check the head log first.
4. **Clean-up needs the user's consent.** Local: `agent/cachetest/20260928_121303` (58 MB) and `agent/cachetest/20260928_121644`
   (50 MB). Hazel, after the run: `/share/maize/frodrig4/nf_work/simplify_cachetest/<time>` (work from 5 runs, stores, checkpoint,
   preflight).
5. **Shell-rule slips.** I ran two multi-line python heredocs directly in the terminal (dump exploration and the edit of
   test_cache.sh), and several chained one-liners (`sed … && grep`, `bash -n … && git add … && git commit`, `ls && rm && rmdir` of my own __pycache__). There was no other effect.
