# sawers-rellan-labs/zealgt: Usage

> _Every parameter is documented in `nextflow_schema.json` (`nextflow run . --help --show_hidden`). This page explains how the
> pieces fit together._

## Introduction

zealgt has two workflows, chosen by `--workflow`, that meet only at the **store** (docs/PLAN_pipeline.md §3):

- `--workflow cram` (default): raw sequencing libraries -> analysis-ready CRAMs + QC + provenance + the demux registry.
- `--workflow genotype`: CRAM store -> ancestry and imputed genotypes (skeleton; not implemented yet).

The CRAM workflow has two entries (`--entry`):

| entry | input | steps | store output |
|---|---|---|---|
| `read_demultiplexing` (default) | `--libraries <lib>` rows of `--input` (meta/samples.csv) | DEMUX (cutadapt, exact inline barcodes) -> DEMUX_QC -> READ_TRIMMING (Trimmomatic, FastQC) -> READ_ALIGNMENT (minibwa, samtools markdup -> CRAM) -> SAMTOOLS_STATS + Picard CollectWgsMetrics -> PROVENANCE -> REGISTRY | `demux_qc/`, `cram/`, `registry/` |
| `markdup_import` | `--import_sheet` (meta/dev_import.csv) | MARKDUP_IMPORT (read groups + samtools markdup, no realignment) -> SAMTOOLS_STATS + Picard -> PROVENANCE | `cram_import/` |

Trimming and alignment are internal steps of `read_demultiplexing`; there is no FASTQ entry (the pre-demultiplexed FASTQs it
would read no longer exist). Both entries end at the CRAM stop point and write one MultiQC report per library (per import set).

## Sample sheets

Both sheets are validated and parsed by nf-schema (`samplesheetToList`); the pipeline does not re-check what the schemas say.

### `--input`: meta/samples.csv (assets/schema_input.json)

The single sample sheet of the project, one row per sequenced well, built by `python3 meta/build_samples.py` from
`meta/sources/` (provenance in `meta/PROVENANCE.md`). It is validated at parameter validation on every run.

| column | rule |
|---|---|
| `sample_id` | `[A-Za-z0-9_.-]+`, unique in the sheet |
| `source` | `bc1`, `bc2s3_batch1`, `bc2s3_batch2` |
| `library` | BC1 pool, batch-2 row or batch-1 plate; what `--libraries` names |
| `raw_location` | absolute directory of the raw library (repo-relative only under `tests/fixtures/`) |
| `raw_r1`, `raw_r2` | batch 1 only: `<tar>:<member>;...` inside `raw_location`, one tar per read; empty for lane FASTQs (`--raw_r1_glob`, `--raw_r2_glob`) |
| `barcode_r1`, `barcode_r2` | inline barcodes (`[ACGT]+`; `barcode_r2` empty for R1-only layouts) |
| `barcode_layout` | `symmetric` (BC1, batch 2: `--read_structure_symmetric`) or `r1_only` (batch 1: `--read_structure_r1_only`) |
| `rg_lb`, `rg_pl` | read-group LB / PL (default the library, ILLUMINA) |

All samples of one library must agree on `source`, `barcode_layout`, `raw_location`, `raw_r1` and `raw_r2` (checked by
build_samples.py and again when the library is read).

### `--import_sheet`: meta/dev_import.csv (assets/schema_import.json)

Existing CRAMs / BAMs made by zealbc1 / nilhmm (no duplicate marking, no read groups). Columns: `sample_id` (unique),
`source`, `role`, `library`, `donor`, `import_set`, `path` + `index` (must exist), `size_bytes`, `made_by`, `dup_marked`,
`read_groups` (ignored: the read group is decided from the input header), `include` (`TRUE`/`FALSE`), `note`.
`--import_samples a,b` and `--import_sets x,y` restrict the rows. This sheet has no `schema` key in `nextflow_schema.json` on
purpose: parameter validation would otherwise stat every CRAM of the sheet on every run of every entry.

## Running on hazel

Everything runs through the head job `scripts/submit_head_job.sbatch` (never the login node; hazel-debug-loop skill), which
takes a run id (scratch directory `/share/maize/frodrig4/nf_work/<run_id>`) and the `nextflow run` arguments:

```bash
sbatch /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch <run_id> -profile hazel,short \
    --workflow cram --entry read_demultiplexing --libraries 1A --outdir /rsstu/users/r/rrellan/BZea/ZEAL/results/zealgt/<run_id>
```

Profiles: `hazel,stub` (Gate 0, `-stub`), `hazel,short` (gates, 1 h cap), `hazel,normal` (Gate 2 and later; heavy tasks on
compute/normal), `hazel,local` (one allocation, per-task cap in `conf/local.config`). The conda prefixes are prebuilt by
`scripts/build_envs.sbatch` (an xfer job) and listed in `conf/env_prefixes.config`; no env is ever built at task time.
Resources are Nextflow directives (`conf/base.config` labels, per-process values in `conf/hazel.config` / `conf/normal.config`)
that the scripts read as `task.cpus` / `task.memory`; a resource change does not rerun cached tasks (Nextflow 26.04.6 does
not hash those values). `scripts/check_resources.sh` checks what each process resolves to (`tests/expected_resources.tsv`).
The head job's log starts with the checkout (`ZG_REPO`, default `ZEAL/zealgt`) and its commit; every Nextflow line carries a
timestamp.

### Store rules

- `--store` (default `ZEAL/store`) is the permanent storeDir root. A stored output is never recomputed, whatever changed.
- `--subsample N` (Gate 1) needs a store directory named `subsample_<N>`, e.g. `--store ZEAL/store/subsample_1000000`, so a
  subset never lands where the real CRAMs go. A store named `subsample_*` without `--subsample` is refused too.
  N is read pairs per library: DEMUX runs once per library x lane, and each of the library's lanes gives its first
  ceil(N / lanes) pairs (the total is N rounded up to a multiple of the lane count).
- Stub runs need a store inside a directory named `store_stub*` and outside `ZEAL/store`; `-profile stub` sets
  `<outdir>/store_stub`.
- A library in the registry (`assets/registry_seed.csv` or `<store>/registry/<lib>.registry.tsv`) is refused unless named with
  `--force_demux <lib>`; at most `--max_libraries` (default 1) libraries per run.
- Samples whose CRAM is already in `<store>/cram` are not trimmed or aligned again; their missing QC and provenance are made.

## Testing

`-profile test` runs `read_demultiplexing` on the fixture library LIBX (tests/fixtures: 3 samples, 940 read pairs, a tiny
reference with its minibwa index). `-profile test,stub -stub` checks the wiring without tools. nf-test runs the module,
subworkflow and pipeline stub tests; `scripts/run_checks.sh` runs everything before a push (docs/CONTRIBUTING.md).

## Deliberate deviations from the nf-core specifications

| deviation | why |
|---|---|
| Conda only, no containers; no `-profile docker` (M6) | hazel compute nodes are offline and run no container engine for this project; every module has a pinned `environment.yml` and a prebuilt prefix. The stale template container configs were removed (.nf-core.yml). |
| Build-pinned conda packages (M10) | linux-64 is the only target, and the hazel prefix is keyed by the sha of `environment.yml`; the pins are what was built and smoke-tested. |
| No GitHub Actions CI (P2) | private offline cluster; `scripts/run_checks.sh` runs the same checks locally before every push. |
| storeDir store, nothing published by default (P15) | CRAMs, demux QC, registry and provenance live in the store and are never recomputed; nf-core QC modules (with `eval` versions, which storeDir forbids) publish into the store instead. |
| Step-named local modules (M11) | `demux`, `demux_qc`, `align_markdup`, `markdup_import`, `provenance`, `registry` name pipeline steps; renaming a module directory renames its hazel conda prefix (rebuild). Each meta.yml names the tools it wraps. |
| One versions.yml per storeDir module (M3) | storeDir does not allow `eval` outputs; the yml lists every tool of the pipe. DEMUX (not storeDir'd) emits one topic tuple per tool. |
| Per-source read structures as two params (P17) | chosen by `barcode_layout`; both values are recorded in every provenance record. |
| `--subsample` / `--max_libraries` typed integer-or-string (P14) | Nextflow 26 hands CLI values over as strings; the schema accepts digit strings and the code converts. |
| CRAM output only, no `--bam` (P12) | the genotype workflow reads CRAM. |
