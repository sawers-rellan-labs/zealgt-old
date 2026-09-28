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
- Provenance record: `registry` snapshot of the sample's `meta/samples.csv` row (`sample_id`, `source`, `role`, `library`,
  `plate`, `well`, `donor`, `taxon`, `nil_id`, `pedigree`, `is_check`) with the registry file and the commit it was read at
  (meta/PROVENANCE.md "Identifiers"); the checkpoint samplesheet carries these columns (+ `registry_file`), so `read_alignment`
  rebuilds the same snapshot; `markdup_import` records look the sample up in the registry and keep the import sheet's row
  (`origin.import_sheet_row`). CRAM headers unchanged (RG `ID` = `SM` = `sample_id`, one per sample).

### `Changed`

- Resources the standard nf-core way (`task.cpus` / `task.memory` in the scripts); the Slurm resource helper and the
  resource-only nf-core module patches are removed.
- Store outputs written by `publishDir` (`overwrite: false`) with explicit skip-if-stored logic instead of `storeDir`
  (deprecated in the Nextflow 26.10 docs); a stored CRAM must pass an index + EOF check and is never overwritten.
- PLAN §2 hash table corrected from the Nextflow 26.04.6 hash test.

### `Fixed`

- `conf/normal.config`: TRIMMOMATIC's 12 h override never applied (lost to a combined selector); removed, 4 h × attempt measured
  sufficient.
- PROVENANCE reran on every `-resume`: its hashed record carried `workflow.runName`; `run_name` is dropped from the record
  (session id, run id and code version identify the run).

### `Dependencies`

### `Deprecated`
