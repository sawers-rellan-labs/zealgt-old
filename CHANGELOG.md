# sawers-rellan-labs/zealgt: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0dev - [unreleased<!-- TODO nf-core: replace with date on release -->]

Initial release of sawers-rellan-labs/zealgt, created with the [nf-core](https://nf-co.re/) template.

### `Added`

- FASTQ checkpoint: `read_demultiplexing` hardlinks each sample's trimmed pair plus a per-library `samplesheet.csv` to
  `params.fastq_checkpoint` and chains into stage 2; `read_alignment` reinstated as stage 2 alone, reading only the checkpoint
  samplesheets; per-library `cleanup_status.tsv` report (nothing is removed by the pipeline).
- Checks: `scripts/check_ext_args.py` (no `task.*` inside `ext.args*` closures), `scripts/check_resources.sh` +
  `tests/expected_resources.tsv` (resolved cpus / memory / time / queue per profile and process).
- ALIGN_MARKDUP / MARKDUP_IMPORT memory parameters (`align_memory_gb`, `align_mem_reserve_gb`, `align_sort_mem_share`,
  `import_mem_reserve_gb`) and an explicit `samtools sort -m` from `task.memory` (Gate 2 OOM analysis).
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

### `Dependencies`

### `Deprecated`
