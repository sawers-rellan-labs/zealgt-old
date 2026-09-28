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
  28 GiB reserve, 0.75 share; hazel kills at 95 % of `--mem`); ALIGN_MARKDUP 10 h × attempt on `normal`.
- Head job: repository and commit printed first, timestamp on every Nextflow console line.

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
