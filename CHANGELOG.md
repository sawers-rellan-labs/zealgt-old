# sawers-rellan-labs/zealgt: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0dev - [unreleased<!-- TODO nf-core: replace with date on release -->]

Initial release of sawers-rellan-labs/zealgt, created with the [nf-core](https://nf-co.re/) template.

### `Added`

- FASTQ checkpoint: `read_demultiplexing` hardlinks each sample's trimmed pair plus a per-library `samplesheet.csv` to
  `params.fastq_checkpoint` and chains into stage 2; `read_alignment` reinstated as stage 2 alone, reading only the checkpoint
  samplesheets; per-library `cleanup_status.tsv` report (nothing is removed by the pipeline). The trim reports
  (`.summary`, `_out.log`) are published with the trimmed pairs into the checkpoint instead of `<outdir>/trimmomatic/`.
- `--max_libraries` (default 4) as a run guard: `read_demultiplexing` is refused when the requested libraries plus those already
  holding a checkpoint dir are more than N (the error names them and their `cleanup_status.tsv`); the requested libraries then
  run concurrently. DEMUX has no `maxForks`.
- Cache test `scripts/test_cache.sh` (+ `scripts/test_cache.sbatch` for hazel, `tests/cache/`): one session resumed with raised
  resources (every task cached), after an ALIGN_MARKDUP edit (stage 1 cached), and `read_alignment` alone; an operator script
  because nf-test cannot share a session across runs.
- Checks: `scripts/check_ext_args.py` (no `task.*` inside `ext.args*` closures), `scripts/check_resources.sh` +
  `tests/expected_resources.tsv` (resolved cpus / memory / time / queue per profile and process).
- ALIGN_MARKDUP / MARKDUP_IMPORT memory parameters (`align_memory_gb`, `align_mem_reserve_gb`, `align_sort_mem_share`,
  `import_mem_reserve_gb`) and an explicit `samtools sort -m` from `task.memory` (Gate 2 calibration: 48 GB first attempt,
  28 GiB reserve, 0.75 share; hazel kills at 95 % of `--mem`).
- Right-sized requests from Gate 2 (`conf/hazel.config`): per-sample times scale with the task's input size
  (TRIMMOMATIC, FASTQC, ALIGN_MARKDUP, SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS: a + b × input GiB, floor 15 min, × attempt),
  replacing the flat 4 h / 10 h on `normal`; smaller cpus / memory where Gate 2 used less (TRIMMOMATIC 6 cpus / 2 GB, Picard 1 cpu /
  5 GB, FASTQC 3 GB, SAMTOOLS_STATS 1 GB, bookkeeping 1 GB / 10 min). `normal` routes each task by its own time request (≤ 1 h 45 →
  compute_partners / short QOS, else compute / normal) and has queueSize 160; `scripts/check_resources.sh` adds a size probe
  (sparse 100 M / 310 M pair inputs). Head job: documented `--qos=normal --partition=compute --time=3-00:00:00` for multi-library runs.
- Head job: repository and commit printed first, timestamp on every Nextflow console line.
- Provenance record: `registry` snapshot of the sample's row of the sample-identity registry (`--registry`, default
  `meta/registry.csv`; meta/PROVENANCE.md "Identifiers"): `row` = the raw identity and biology columns as the sources give them
  (38 columns, the registry's spelling, e.g. `FALSE`), `resolved` = `pedigree_resolved`, `nil_id_resolved`, `donor_resolved`,
  `correction_ids` recorded separately (never replacing a raw value), with the registry file and the commit it was read at. The
  checkpoint samplesheet carries the row as `reg_<column>` (+ `registry_file`, `registry_note`), so `read_alignment` rebuilds the
  same snapshot; `markdup_import` records look the sample up in the registry and keep the import sheet's row
  (`origin.import_sheet_row`). A registry row must agree with `--input` on source and library. CRAM headers unchanged (RG `ID` =
  `SM` = `sample_id`, one per sample).
- Every run with stage 2 writes `<outdir>/pipeline_info/cleanup_<run_id or session>.sh` (also printed in the log) with, per
  library whose CRAMs are all stored and verified, listing commands and commented consent-marked removal lines for its
  checkpoint dir and the run's DEMUX / MERGE_LANES / TRIMMOMATIC / FASTQC work dirs (sizes and file counts measured at the end
  of the run). It also gives a `nextflow clean` alternative when every library is removable. The pipeline never runs it. Gate 3
  runs as waves of <= `--max_libraries` libraries with a consented cleanup between waves (PLAN §5, §6; docs/usage.md).
- Batch-1 read-group PU: `rg_pu` column in `meta/samples.csv` / `meta/registry.csv` (`meta/build_samples.py`: flowcell
  `H7HYFDSX7` from the read headers, lanes from the tar member names, e.g. `H7HYFDSX7.1,H7HYFDSX7.2`; empty for BC1 / batch 2,
  whose PU still comes from the Novogene lane file names); `assets/schema_input.json` validates it; all samples of a library
  must agree on it.
- Batch-1 test fixture `tests/fixtures/raw/LIBB1/R{1,2}.tar` (one plate pool, 2 lane members per read, R1-only 8-bp barcodes,
  `8B12S+T 8S+T`, one empty well) with `tests/fixtures/registry_test.csv`; DEMUX nf-tests (stub, and `demux_real` tests that check
  R1 = raw[20:], R2 = raw[8:], per-well counts and the subsample path) and a pipeline stub test for `--libraries LIBB1`.
- `scripts/build_envs.sh --prefixes` (prefix -> processes, state on disk), `--list-stale [--all-refs | <ref>...]` (prefixes under
  the env root that neither this checkout nor the named branches reference; listing only) and `--inodes [<prefix>...]` (own
  inodes per prefix, `find <prefix> ! -type f -o -type f -links 1 | wc -l`, and all entries); `scripts/run_checks.sh` checks that
  `conf/env_prefixes.config` is current.
- DEMUX nf-tests (`demux_real`) that a truncated tar member and a missing member fail a `--subsample` task
  (`tests/fixtures/raw/LIBB1_BAD/R1.tar`).

### `Changed`

- Resources the standard nf-core way (`task.cpus` / `task.memory` in the scripts); the Slurm resource helper and the
  resource-only nf-core module patches are removed.
- Store outputs written by `publishDir` (`overwrite: false`) with explicit skip-if-stored logic instead of `storeDir`
  (deprecated in the Nextflow 26.10 docs); a stored CRAM must pass an index + EOF check and is never overwritten.
- PLAN §2 hash table corrected from the Nextflow 26.04.6 hash test.
- Conda prefixes keyed on content only: `<first dependency>-<sha8>` of the environment.yml without comments / blank lines /
  `name:` (+ build.sh), so identical envs share one prefix (DEMUX_QC, PROVENANCE, REGISTRY: one python prefix) in every branch
  built into the same root, and a comment edit no longer forces a rebuild. Every prefix name changes once (hazel rebuild; old
  prefixes are kept until the user removes them). `conf/env_prefixes.config` has one line per process.
- MERGE_LANES has its own `environment.yml` (coreutils, pinned as DEMUX's) instead of borrowing DEMUX's;
  `envs/process_aliases.tsv` is removed (the alias mechanism stays in `scripts/build_envs.sh` for `include { X as Y }`).
- Versions: DEMUX_QC, PROVENANCE and REGISTRY keep their versions.yml (python module templates; Nextflow 26.04.6 refuses an
  `eval` output for a non-Bash script), ALIGN_MARKDUP / MARKDUP_IMPORT theirs next to the CRAM (provenance of an already stored
  CRAM reads it); recorded as a deliberate deviation. No change to the version outputs.
- Deliberate deviations from nf-core: one list, word for word, in `.nf-core.yml`, `docs/usage.md`, `docs/PLAN_pipeline.md` §2
  and the nfcore-compliance skill (step-named local modules, storeDir and the Slurm helper are no longer on it).
- PLAN §6 testing ladder per workflow: CRAM minimal gates (stub, subsample through the full code path, cache tests, memory
  test) → CRAM Gate 2 on the genotype development donors' libraries at full depth into the production store (BC1 2A, 2B, 2F,
  2H, 3B, 3C, 3D, 3E with `--force_demux`; batch-1 BZea5, BZea6, BZea8, BZea9; B73 controls via `markdup_import`; waves of 4,
  checkpoint kept until the genotype Gate 2) → genotype Gate 1 / 2 on those CRAMs → the full dataset in waves on the user's go.

### `Fixed`

- `conf/normal.config`: TRIMMOMATIC's 12 h override never applied (lost to a combined selector); removed, 4 h × attempt measured
  sufficient.
- PROVENANCE reran on every `-resume`: its hashed record carried `workflow.runName`; `run_name` is dropped from the record
  (session id, run id and code version identify the run).
- TRIMMOMATIC exited 1 on a sample with no reads ("Unable to detect quality encoding"): the functional patch adds
  `ext.args3` before the inputs, set to `-phred33` (conf/modules.config); the provenance record's `trimming.phred` is `phred33`.
- DEMUX `--subsample` read plain FASTQ while the full run reads gz: the head of each lane is now re-compressed (`pigz -1`), so
  Gate 1 takes the full run's I/O path for tar and plain-FASTQ libraries alike; task-dir copies (tar members, heads) are removed
  by an EXIT trap, also when cutadapt fails.
- Batch-1 lane names kept Illumina's `_R1_001` (`BZea5_S5_L001_R1_001`): now `BZea5_S5_L001`; R1 / R2 tar members are checked to
  be the two reads of one lane (`_R1_<nnn>` / `_R2_<nnn>`) instead of pairing by position only.
- `read_alignment` read the registry columns of the checkpoint samplesheet through nf-schema's type inference (`FALSE` →
  `false`); the samplesheet's text is now used, so both entries record the registry's own spelling.
- DEMUX `--subsample`: pipefail was off around `… | head`, so a failing `tar` / decompression before `head` gave a short or
  empty lane silently. The producer stages' exit codes are now checked (`PIPESTATUS`: 0 or 141 = SIGPIPE from head's early
  exit; head and the compressor 0), so a corrupt or missing input fails the task.

### `Dependencies`

### `Deprecated`
