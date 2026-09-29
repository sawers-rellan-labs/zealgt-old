---
name: nfcore-compliance
description: Keep a Nextflow pipeline compliant with the nf-core specifications (https://nf-co.re/docs/specifications/overview).
  Use whenever writing, reviewing or refactoring modules, subworkflows, configs, nextflow_schema.json or the samplesheet schema
  of an nf-core-template pipeline (zealgt included), when patching an installed nf-core module, and before any push of pipeline
  code (pre-push checklist).
---

# nf-core compliance

Rules below are the ones most often broken in practice, each with its spec page. MUST = spec requirement; anything you cannot
meet is a **deliberate deviation**: record it with a reason (see last section), never leave it silent.
Spec index: https://nf-co.re/docs/specifications/overview

## Modules — https://nf-co.re/docs/specifications/components/modules/general
- **Only standard meta keys inside a module** ("custom hardcoded `meta` fields MUST NOT be used"). Anything else a script needs
  (read group, read structure, tar members, …) comes in as its own `val`/`path` input; keep bulky records out of `meta` (it is hashed).
- **All input files are staged inputs** — never an absolute path inside `ext.args` (not staged, and the path enters the hash).
- **A version for every tool the script calls** (one emission per tool; `eval` topic tuples preferred). Versions are numeric, no
  leading `v`. Stubs report real-looking versions (the pinned ones), never the word `stub`.
- **`${args}` per tool** (`task.ext.args`, `args2`, `args3`, … in pipe order); `def prefix = task.ext.prefix ?: "${meta.id}"`,
  and output names are `${prefix}` + suffix (…/modules/naming-conventions).
- **One output channel per file type**, no duplicate emissions (…/modules/input-output-options).
- **Helper scripts**: module `templates/` (`script: template 'x.py'`) or `bin/` on the task PATH, called by name. Never write
  `${projectDir}`/`${moduleDir}` paths into the script text: the absolute checkout path enters every task hash, so a second
  clone or moved checkout reruns everything.
- Multithreading and memory come from the `task` variable or the config, never hardcoded (…/modules/resource-requirements).
- Conda/container: `environment.yml` per module (…/modules/software-requirements).

## Module docs and tests
- **Complete `meta.yml`** (…/modules/documentation): `tools` with `args_id`, every input/output entry split into meta + file,
  `type`/`pattern` (Java glob) on files, versions/topics, real GitHub handles as authors. Copy an installed nf-core module's layout.
- **nf-test with snapshots** (…/modules/testing): at least one success assertion, `snapshot(process.out).match()` including
  versions, an existence check for binary files; stub test at minimum. Commit the `.snap` files.
- **Subworkflows** (…/subworkflows/general, /testing): emit `versions`; `take:` declares every input file (no `file().exists()`
  inside); stub test with `tag` for every dependent module and `assertAll()` + snapshot.

## Installed nf-core modules — https://nf-co.re/docs/specifications/pipelines/requirements/use_the_template
- Never hand-edit `modules/nf-core/**`. Change them only via `nf-core modules patch <tool>` (diff recorded in modules.json, so
  `nf-core modules update` carries it). Move an old `.diff` aside first — the tool refuses to overwrite non-interactively.
- Keep patches minimal, functional and commented, with the reason in a comment above the changed line (it lands in the
  `.diff`). No resource-only patches: upstream's `${task.cpus}` / `task.memory` in the script are not hashed on Nextflow
  >= 26.04.6 (`nextflow-cache` skill). Rerun the module's own nf-test after patching; update its snapshot.

## Samplesheets and params — https://nf-co.re/docs/specifications/pipelines/requirements/parameters
- `--input` is a CSV validated by nf-schema: `"schema": "assets/schema_input.json"` on the param, parsed in
  `PIPELINE_INITIALISATION` with `samplesheetToList`. No hand parsing/validation in the workflow.
- Push checks into the schema: `uniqueEntries`, `maximum`/`minimum`, `pattern`, `format: file-path|directory-path`, `exists`
  (nf-schema spec: https://nextflow-io.github.io/nf-schema/latest/nextflow_schema/nextflow_schema_specification/).
- Workflows are wiring only; input building and run guards live in the utils subworkflow (template code locations).

## Pipeline — https://nf-co.re/docs/specifications/pipelines/requirements/use_the_template
- Built on the template (`nf-core pipelines create`); follow its file locations. `bin/` = scripts tasks run; operator scripts elsewhere.
- **Lint MUST have 0 failures** (…/pipelines/requirements/linting); fix warnings or justify them in `.nf-core.yml`.
- `-profile test` runs on small bundled data (…/pipelines/requirements/ci_testing, …/recommendations/testing).
- `README.md`, `docs/usage.md`, `docs/output.md` describe this pipeline, not template text (…/pipelines/requirements/documentation).
- Delete dead template code (unused workflows, stale container configs, unused params).

## Pre-push checklist
1. `nf-core pipelines lint --dir .` → 0 failed.
2. `nf-core pipelines schema lint nextflow_schema.json` → valid.
3. `nextflow lint main.nf workflows subworkflows/local modules/local nextflow.config conf` → 0 errors.
4. `nf-test test --tag stub` (plus any real-mode tests) → all pass; snapshots committed.
5. Local `-stub` run of every entry (`nextflow run . -profile test,stub -stub [--entry …]`) → SUCCESS, expected task counts.
6. Code review on the exact commit, findings fixed or rejected in writing; re-review after fixes.

## This repository (zealgt)
- One command for 1–4: `ZG_CHECK_PATH=$PWD/agent/bin:$PWD/agent/.venv_nfcore/bin:$PWD/agent/stubbin NXF_VER=26.04.6 bash scripts/run_checks.sh`
  (`--quick` = lints only). `agent/bin` has nextflow + nf-test, `agent/.venv_nfcore` nf-core tools, `agent/stubbin` version shims.
- Review gate (user rule, 2026-09-29): `coderabbit review --committed --base-commit <last reviewed> --agent`, required on the exact
  commit before a **costly** run (Gate 2 and up, full libraries, production, > ~20 CPU-h); cheap diagnostics (Gate 0/1, subsample tests,
  comparisons) do not wait. **Scope: only code that executes** — `modules/`, `subworkflows/`, `workflows/`, `conf/`, `nextflow.config`,
  templates, `bin/`, `scripts/` submitted to hazel, tests; never `agent/` (untracked scratch), `docs/`, `meta/` data or handovers.
  Review small and often (right after code commits) so diffs stay small; findings fixed or rejected in writing (log in `agent/`).
- Deliberate deviations from the nf-core specifications. The same list, word for word, is in `.nf-core.yml`,
  `docs/usage.md`, `docs/PLAN_pipeline.md` §2 and the nfcore-compliance skill; a new deviation goes into all four, with its
  reason.
  - **No containers** (spec: Docker / Singularity support). Hazel compute nodes are offline and run no container engine for
    this project; every module has a pinned `environment.yml` instead. The template's container configs
    (`conf/containers_*.config`) are removed and gitignored (`nf-core modules install/patch` regenerates them), and the
    `container_configs` lint test is off.
  - **No GitHub Actions CI** (spec: CI testing). The pipeline runs on a private offline cluster; `scripts/run_checks.sh`
    runs the same checks on the laptop before every push (nf-core lint, schema lint, nextflow lint, nf-test, the env prefix
    and resolved-resource checks; docs/CONTRIBUTING.md).
  - **Build-pinned conda prefixes set per process in the site config** (spec: conda packages pinned by version, envs created
    by Nextflow). `conf/env_prefixes.config`, generated by `scripts/build_envs.sh --write-config` and included by the hazel
    and local profiles only, sets each process's `conda` to a prebuilt prefix on `/share` (config `conda` overriding the
    module's, the standard Nextflow override). A prefix is keyed on the content of `environment.yml` (+ `build.sh`) only, so
    identical envs share one prefix; local modules pin version and build (linux-64 is the only target); the prefixes are
    built once by an xfer job (compute nodes are offline), never at task time.
  - **Cache test as an operator script, not an nf-test** (spec: tests are nf-test). `scripts/test_cache.sh` resumes one
    Nextflow session across several runs (raised resources, an edited module, stage 2 alone) and compares the task hashes;
    nf-test starts a new session for every run and cannot share one.
  - **Permanent store and FASTQ checkpoint outside `--outdir`** (spec: outputs published to `--outdir`). CRAMs, QC,
    provenance, demux QC and the registry are copied into `--store` (never overwritten) and the workflow skips work whose
    stored output exists; the trimmed pairs are hardlinked into `--fastq_checkpoint` (the filesystem of `work/`), with
    CUTADAPT's log (one `publishDir` map: a second one whose path uses `meta` breaks `nextflow config -o json`, so nf-core
    lint). Only reports go to `--outdir`.
  - **`versions.yml` files for five local modules** (spec: versions as `eval` topic tuples). ALIGN_MARKDUP and
    MARKDUP_IMPORT publish theirs next to the CRAM, one line per tool of the pipe, because PROVENANCE of an already stored
    CRAM (skipped, not made again) needs the versions of the tools that made it; DEMUX_QC, PROVENANCE and REGISTRY are
    python module templates, and Nextflow allows `eval` outputs only with Bash scripts. DEMUX and the nf-core modules report
    `eval` topic tuples; coreutils (DEMUX's `head`, MERGE_LANES's `cat`) is pinned in `environment.yml` but not reported
    (the BSD tools of the laptop's local runs have no `--version`).
  - **Stage-2 samplesheet written by the pipeline** (spec: inputs through `--input`).
    `<fastq_checkpoint>/<lib>/samplesheet.csv` is an output of stage 1 and the only input of `--entry read_alignment`,
    validated by nf-schema against `assets/schema_checkpoint.json`.
  - **`--subsample` / `--max_libraries` typed integer-or-string** (spec: typed parameters). Nextflow 26 hands CLI values
    over as strings; the schema accepts digit strings and the code converts.
  - **Per-source read structures as two parameters** (`read_structure_*`, chosen by `barcode_layout`), not one per sample;
    both values are recorded in every provenance record.
  - **CRAM output only, no `--bam`**: the genotype workflow reads CRAM.
- **Never change the dependencies of an `environment.yml` or a `build.sh`** without rebuilding the hazel envs (the prefix is
  `<first dependency>-<sha8 of the content>`, shared by identical envs; `scripts/build_envs.sh --prefixes`; see
  `hazel-debug-loop`). Every module has its own `environment.yml` (never a borrowed one); an identical copy costs no extra prefix.
- Script names are verb_object (`build_envs.sh`, `write_provenance.py`); nf-core module names stay tool/subtool.
- Functional patches: none remain (the TRIMMOMATIC patches, no `-trimlog` and `-phred33` before the inputs, went with the
  module when CUTADAPT replaced it, 2026-09-29). A past example of a valid one: dropping an output that costs ~282 GB of
  unread `work/` per library (Trimmomatic's `-trimlog`).
