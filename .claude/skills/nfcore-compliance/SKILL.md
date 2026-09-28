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
- Review gate: `coderabbit review --committed --base-commit <base> --agent` (log in `agent/`), before any hazel data run.
- Deliberate deviations, recorded with reasons in `.nf-core.yml` and `docs/usage.md` "Deliberate deviations": no Docker/containers
  (offline cluster), no GitHub CI (`scripts/run_checks.sh` instead), storeDir store, per-source read-structure params, prebuilt build-pinned per-module conda prefixes (`conf/env_prefixes.config`),
  step-named local modules. Add new ones there, with a reason.
- **Never edit an `environment.yml`/`build.sh` or rename a `modules/local` dir** without rebuilding the hazel envs (the prefix
  name is `<module>-<sha8>`; see `hazel-debug-loop`).
- Script names are verb_object (`build_envs.sh`, `write_provenance.py`); nf-core module names stay tool/subtool.
- Example functional patch: TRIMMOMATIC without `-trimlog` (~282 GB of unread `work/` per library; `trim_log` kept optional).
