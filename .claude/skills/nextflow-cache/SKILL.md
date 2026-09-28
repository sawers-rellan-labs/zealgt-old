---
name: nextflow-cache
description: How Nextflow's task hash, -resume and output reuse actually behave, and how to design and verify a pipeline so code or resource edits do not rerun expensive work. Use when designing processes/entries that produce costly outputs, before changing a module of a pipeline with finished or running work, when a -resume unexpectedly reruns (or fails to rerun) tasks, or when choosing between storeDir, publishDir and explicit checkpoints.
---

# Nextflow cache and resume

Tested on Nextflow 26.04.6 (build 12646); behaviour has changed across versions, so re-test on yours (last section).
Sources: https://docs.seqera.io/nextflow/cache-and-resume, https://seqera.io/blog/demystifying-nextflow-resume/,
nextflow-io/nextflow issues #3581, #413, discussion #5612, PR #7574; zealgt test `agent/20260928_081500_hashtest_results.md`.

## What the task hash covers
- **Hashed:** session id, full process name, the script text **before** `${...}` substitution, inputs (path + size + mtime in the
  default mode; path + size with `cache 'lenient'`; file content only with `cache 'deep'`), container / conda / modules, referenced
  params and globals, the **evaluated** value of any `task.ext.*` the script uses, stub vs script, templates (by content), and
  executables in `bin/` that the script names as a plain word (by content).
- **Not hashed:** directives — `cpus`, `memory`, `time`, `errorStrategy`, `maxRetries`, `queue`, `clusterOptions`, `publishDir`,
  `storeDir`. `${task.cpus}` / `${task.memory}` written in the script do **not** invalidate the cache (tested; issue #3581, "wontfix" on
  22.04, no longer reproduces). Consequence: a cached task's outputs may reflect the old resource values (e.g. a logged thread count).
- **Trap 1:** resources inside an `ext.args` closure (`ext.args = { "-t ${task.cpus}" }`) **are** hashed via the evaluated value — a
  resource change reruns the task. Keep `task.*` out of `ext.args`; pass threads/memory in the script.
- **Trap 2:** a `bin/` script that is not executable, or is called through an interpreter by path (`bash ${projectDir}/bin/x.sh`,
  `python ${moduleDir}/x.py`), is **not** hashed — editing it silently keeps stale outputs. Put output-affecting helper code in module
  `templates/` (hashed by content) or an executable `bin/` script called by name. Do not hide logic from the hash on purpose
  (maintainers call it a bug, not a feature).

## What the cache is not
- A cache entry is reusable only by the same process within the same session (`-resume <session-id>`); it is not a checkpoint
  across launches, pipelines, renamed processes or other entries (maintainer, discussion #5612).
- Any edit to a `script:` block reruns that task and every downstream task (their inputs are new paths), even if the bytes are
  identical — unless downstream uses `cache 'deep'`, which reads whole files to hash them (expensive for 100 GB FASTQs).
- `storeDir` skips a task whenever its output exists, whatever changed — including a bug fix in that task. It is being deprecated
  (26.10 docs, PR #7574); the documented replacement is explicit workflow logic.

## Designing for cheap fixes
- Put a **published checkpoint** after each expensive stage and make the next stage an entry that reads it: stage outputs published
  (on the same filesystem as `work/`, `publishDir mode: 'link'` costs no extra space or inode) plus a samplesheet; the next stage
  skips items whose final output already exists (explicit "use the stored output if it exists, else compute"). A fix to a late stage
  then never reruns an early one; a fix to an early stage reruns only that stage.
- Keep the expensive, stable command in the `script:` block short and free of incidental logic (logging, guards, formatting); put
  resource choices in config directives (not hashed).
- Comments and notes outside the `script:` block (Groovy `//`), never bash `#` inside it.

## Verify, don't assume
- On your own version, before building machinery around cache behaviour: a tiny pipeline, two runs with `-resume <session>` and
  `-dump-hashes json`, diff the dumped hash entries of each task to see which component changed.
- For a real run that reran unexpectedly: `-dump-hashes json` on both runs, or `nextflow lineage diff` (≥ 25.04, experimental); fix
  the cause instead of forcing reuse. To force one step to rerun, delete its stored output or set `cache false` on that process.

## This repository (zealgt)
- hazel's `/rsstu` ACL strips the exec bit, so every `bin/` script in the hazel checkout is non-executable → invisible to the cache
  (Trap 2); output-affecting helpers belong in module templates.
- Decisions that follow from this skill (Slurm resource helper dropped, FASTQ checkpoint by hardlink, two-stage CRAM workflow, explicit
  skip-if-stored instead of storeDir) are in `docs/PLAN_pipeline.md` §2/§3/§5 and `agent/prompt_20260929_simplify_cache_checkpoint.md`.
