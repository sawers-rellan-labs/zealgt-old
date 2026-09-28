# Handover: end-of-run cleanup commands + Gate 3 waves, branch `simplify`, 2026-09-28 19:55

Base: cbf905f. Not pushed; no CodeRabbit; no hazel. Coordinator decision kept: `--max_libraries` run guard (unchanged code).

## Commits
- `9f8aa95` End-of-run cleanup commands per library (never run); Gate 3 as waves of <= N libraries
- this handover (`git add -f`)

## Design as built
- **File** `<outdir>/pipeline_info/cleanup_<run_id or session id>.sh`, written from `workflow.onComplete` (success or failure)
  for entries read_demultiplexing / read_alignment, and printed in the log (full text after
  `zealgt: cleanup commands (never run by the pipeline; ...): <file>`). The pipeline never runs it. It is a plain file (not
  chmod +x). A `-resume` with the same run id / session rewrites it.
- **Header**: never run by the pipeline, read it all before use; the run's name, session, run_id, entry, code version, time;
  launch dir, work dir, CRAM store. Also: what "removable" means; the hardlink note (space is freed only once both checkpoint
  and TRIMMOMATIC dirs are gone); what removal costs (no read_alignment from it, a -resume redoes stage 1, the dir stops
  counting against --max_libraries); failed / retried attempts are not listed (`nextflow log <run> -f name,status,workdir`).
- **Per removable library** (`zgCheckpointCleanupReport`, which now returns `[library, dir, removable, status, rows]`):
  - checkpoint dir stats, then active `ls -la`, `du -sh`, `find -maxdepth 1 ! -type d | wc -l`, `cat cleanup_status.tsv`;
  - this run's DEMUX / MERGE_LANES / TRIMMOMATIC / FASTQC task dirs of that library. Each has process, path, file count, size
    and hardlinked bytes. They go into a `work_dirs=( ... )` array, then `du -shc` and `find -maxdepth 3 ! -type d | wc -l`;
  - `# CONSENT:` line, then one commented `# rm -r -- '<path>'` per task dir plus one for the checkpoint dir.
  - read_alignment runs have no stage-1 dirs. The file then names the stage-1 session and run_id, whose own cleanup file lists
    them.
- **Not complete**: `# ==== library X: keep: k of n CRAMs missing; no removal line ====` (or `keep: no samplesheet.csv` /
  `does not validate`).
- **`nextflow clean` alternative** at the end, offered only when every library is removable. It has a commented dry run
  (`cd <launch>`, `nextflow clean -n <run>`) and `# CONSENT: nextflow clean -f <run>`. On hazel it runs as a short-QOS job, and
  it never touches the checkpoint. Otherwise the file says "not offered: library ... is not removable".
- **Where the task dirs come from**: the processes' output channels.
  - New emits `task_outputs` = `[library, process, one output file]` on READ_DEMULTIPLEXING (DEMUX json, MERGE_LANES first read)
    and READ_TRIMMING (TRIMMOMATIC first read, FASTQC first zip).
  - In workflows/cram.nf, `zgTaskDir(file, workflow.workDir)` = `<workDir>/<2 chars>/<rest>`. It is not the file's parent,
    because DEMUX / MERGE_LANES outputs sit in `demux/`.
  - The result goes out as `CRAM.out.task_dirs` -> `SAWERSRELLANLABS_ZEALGT.out.task_dirs` -> a new PIPELINE_COMPLETION input
    `ch_task_dirs`. That input is subscribed into a synchronized list, which onComplete reads.
  - Cached tasks are included, because their outputs point to the original dir.
  - The trace file was rejected: it has no library, only the hash prefix, and it is still open in onComplete. Documented in the
    function header and in PLAN §5 rule 4.
- **Sizes**: `zgDirStats(path, depth)` uses `Files.walk` with a depth bound (checkpoint 1, task dirs 3) and NOFOLLOW_LINKS.
  - files = non-directory entries (symlinks count: inodes);
  - bytes = regular files;
  - hardlinked = regular files with `unix:nlink` > 1.
  It walks only the listed dirs.
- No process, env, conf or module change. Task hashes are unchanged (workflow/subworkflow logic only).

## Docs
- PLAN §5 rule 3: why the semaphore was rejected (it bounds concurrency, not the FASTQs held, under no-auto-delete), plus the
  waves sentence. Rule 4: the cleanup file, and how task dirs are collected. The old `nextflow clean -f -but <last>` sentence is
  replaced by the file's workflow.
- §6 Gate 3: waves of <= N, the between-wave consented cleanup, and why not a semaphore. New lesson "Bound what is held, not what
  runs".
- docs/usage.md: cleanup-report bullet gets a pointer. New operator section "Waves of libraries (Gate 3) and the cleanup file",
  4 steps. docs/output.md: `pipeline_info/cleanup_*.sh` entry, and a pointer in the checkpoint paragraph.

## Tests / checks (logs in agent/)
- tests/default.nf.test: `pipeline_info/cleanup_*.sh` is added to the stable_path ignore list and to tests/.nftignore, because the
  name holds the session id. No .snap change.
  - read_demultiplexing asserts: one file, header, LIBX removable, "9 dirs (DEMUX 2, MERGE_LANES 1, TRIMMOMATIC 3, FASTQC 3)",
    10 commented rm lines, no active rm, the nextflow clean alternative.
  - read_alignment asserts: one file, the "no stage-1 task" line, 1 rm line.
- `scripts/run_checks.sh` full, final result:
  - nf-core lint 280 passed / 10 warnings / 0 failed; schema ok; nextflow lint 43 files no errors; ext.args ok; nf-test 18/18;
    check_resources 46 rows 0 problems -> `20260928_195000_run_checks.txt`.
  - The first pass (`20260928_193000_run_checks.txt`) failed only in check_resources.sh, with "syntax error near `done`" at line
    161. That was the other writer's in-progress edit; it was fine on rerun.
- Local runs, `agent/20260928_191500_local_runs_cleanup.sh [stub|real]` (dir `agent/20260928_191500_localrun/`):
  - stub (`_stub.txt`):
    - chained: 24 tasks, removable, 9 dirs;
    - read_alignment from that checkpoint: 13 tasks, no stage-1 dirs, 1 rm line;
    - chained with ALIGN_MARKDUP failing (`agent/20260928_191500_fail_align.config`): keep 3 of 3, no removal line, clean not
      offered;
    - LIBX,LIBY N=2 `--run_id wave1`: `cleanup_wave1.sh`, both removable (9 + 7 dirs).
    - Every file passes `bash -n` and has 0 active rm lines.
  - real chained (`_real.txt`): 24 tasks SUCCESS. The file lists 9 dirs, 173 files, 7.4 MB (65.6 kB hardlinked), and a checkpoint
    of 14 files. Running the file unchanged gave only listings, and its `du -shc` total (7.4M) and file count (173) match the
    pipeline's numbers. The log holds the full text (10 rm lines).

## CHANGELOG line (for the coordinator; I did not edit CHANGELOG.md)
- Added: every run with stage 2 writes `<outdir>/pipeline_info/cleanup_<run_id or session>.sh` (also printed in the log) with,
  per library whose CRAMs are all stored and verified, listing commands and commented consent-marked removal lines for its
  checkpoint dir and the run's DEMUX / MERGE_LANES / TRIMMOMATIC / FASTQC work dirs (sizes and file counts measured at the end
  of the run). It also gives a `nextflow clean` alternative when every library is removable. The pipeline never runs it. Gate 3
  runs as waves of <= `--max_libraries` libraries with a consented cleanup between waves (PLAN §5, §6; docs/usage.md).

## Open points
- Failed / retried attempts' task dirs (they can hold demux FASTQs, e.g. an OOM-retried DEMUX) are not in the per-library lists,
  only reachable with `nextflow log` / `nextflow clean`. A trace-based supplement is possible if wanted.
- Not listed: DEMUX_QC dirs (they stage MERGE_LANES outputs as symlinks only) and stage-2 dirs (ALIGN_MARKDUP intermediates, the
  CRAM before its copy). The `nextflow clean` alternative covers them.
- The `nextflow clean -f <run>` wording assumes the run's cache index includes the tasks it reused as cached. The file tells the
  user to check with `-n` first. Not verified on 26.04.6.
- Log readability: the multi-line log.info appears run together with the other zealgt lines on the non-ANSI console (the same
  cosmetic issue as before).
- hazel-debug-loop skill not updated (the other writer is editing it). It could get a line pointing to the cleanup file for the
  between-wave step.
- Shell-rule slips: two empty heredocs typed in the terminal (`cat > agent/20260928_190000_edit_task_outputs.py <<'EOF'` and
  `python3 - <<'EOF'`). Both were empty, with no effect except an empty file `agent/20260928_190000_edit_task_outputs.py`, which
  is left for the user (removal only with consent).
- Scratch left for the user (removal only with consent): `agent/20260928_191500_localrun/`,
  `agent/check_resources/20260928_150834` and the check_resources dir of the second pass.
