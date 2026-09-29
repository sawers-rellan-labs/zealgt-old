# sawers-rellan-labs/zealgt: Usage

> _Every parameter is documented in `nextflow_schema.json` (`nextflow run . --help --show_hidden`). This page explains how the
> pieces fit together._

## Introduction

zealgt has two workflows, chosen by `--workflow`, that meet only at the **store** (docs/PLAN_pipeline.md §3):

- `--workflow cram` (default): raw sequencing libraries -> analysis-ready CRAMs + QC + provenance + the demux registry.
- `--workflow genotype`: CRAM store -> ancestry and imputed genotypes (skeleton; not implemented yet).

The CRAM workflow runs in two stages with a **FASTQ checkpoint** between them, and has three entries (`--entry`):

| entry | input | steps | output |
|---|---|---|---|
| `read_demultiplexing` (default) | `--libraries <lib>[,...]` rows of `--input` (meta/samples.csv) | stage 1: DEMUX (cutadapt, exact inline barcodes, per lane) -> MERGE_LANES -> DEMUX_QC -> READ_TRIMMING (Trimmomatic -> FASTQ checkpoint, FastQC); then stage 2 in the same run | checkpoint `<lib>/`; store `demux_qc/`, `cram/`, `registry/` |
| `read_alignment` | `--libraries <lib>[,...]`: `<fastq_checkpoint>/<lib>/samplesheet.csv` only | stage 2: READ_ALIGNMENT (minibwa, samtools markdup -> CRAM) -> SAMTOOLS_STATS + Picard CollectWgsMetrics -> PROVENANCE -> REGISTRY | store `cram/`, `registry/` |
| `markdup_import` | `--import_sheet` (meta/dev_import.csv) | MARKDUP_IMPORT (read groups + samtools markdup, no realignment) -> SAMTOOLS_STATS + Picard -> PROVENANCE | store `cram_import/` |

One `read_demultiplexing` command per request runs both stages; stage 2 takes the trimmed reads straight from TRIMMOMATIC
(not from the published files). After a fix to stage 2, `--entry read_alignment` reruns stage 2 alone from the checkpoint,
without demultiplexing again (nextflow-cache skill: the task cache does not carry across entries, the checkpoint does). All
entries end at the CRAM stop point and write one MultiQC report per library (per import set).

### FASTQ checkpoint (`--fastq_checkpoint`, default `/share/maize/frodrig4/fastq_checkpoint`)

- TRIMMOMATIC's `publishDir` **hardlinks** each sample's trimmed pair to `<fastq_checkpoint>/<lib>/<sample>.paired.trim_{1,2}.fastq.gz`
  (same inode as the `work/` file: no extra space or inode while `work/` holds it). The checkpoint must be on the filesystem of
  `work/` (`/share` on hazel); a failed link fails the run.
- Once every sample of the library is trimmed, the run writes `<lib>/samplesheet.csv` (assets/schema_checkpoint.json), one row per
  sample with everything stage 2 needs: `sample`, `library`, `fastq_1`, `fastq_2`, `source`, `role`, `donor`, `taxon`,
  `registry_file` (the `--registry` the snapshot was read from), `registry_note` (empty, or `sample_id not in the registry`),
  `reg_<column>` (the sample's `meta/registry.csv` row for the provenance record's registry snapshot: 38 raw identity and biology
  columns plus `pedigree_resolved`, `nil_id_resolved`, `donor_resolved`, `correction_ids`; read back as text), `read_group`, `read_structure` (crops already applied), `layout`, `barcode_r1`, `barcode_r2`, `demux_args`,
  `trim_illuminaclip`, `trim_args`, `trim_adapters`, `raw_location`, `raw_files_r1`, `raw_files_r2`, `tar_members_r1`,
  `tar_members_r2` (`;`-joined lists), `subsample`, `stage1_run_id`, `stage1_session_id`, `stage1_code_version`,
  `stage1_tool_versions` (`tool=version;...` of DEMUX and TRIMMOMATIC). Both stage-2 entries build meta, read group and the
  provenance record from these columns with the same function, so the records differ only in the run fields.
- `read_alignment` validates the sheet with nf-schema (the FASTQs must exist). It does not demultiplex, so no registry guard
  applies; it needs `<store>/demux_qc/<lib>.tsv` for the registry entry (without it the library is aligned, not registered,
  with a warning).
- `read_demultiplexing` refuses a library whose checkpoint samplesheet was written by another session: use `--entry
  read_alignment`, or `-resume <that session>`, or `--force_demux <lib>` (demultiplexes again and replaces the checkpoint).
- **Cleanup report** (nothing is ever removed): after every run with stage 2, per library, `<lib>/cleanup_status.tsv` lists per
  sample the CRAM, `cram_bytes`, `verified` (yes/no, the store check below) and both FASTQs with their sizes, and ends with (also
  in the log) `# checkpoint <dir>: removable (N files, X GB) — remove only with the user's consent` or `# checkpoint <dir>: keep:
  k of n CRAMs missing`. Removing the checkpoint frees space only once `work/` no longer holds the same files (hardlinks).
  The same run writes the commands to check and (with consent) remove each removable library's checkpoint and stage-1 `work/`
  dirs to `<outdir>/pipeline_info/cleanup_<run_id or session>.sh` (never run by the pipeline; "Waves of libraries" below).

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
| `rg_pu` | read-group PU, `flowcell.lane[,flowcell.lane...]`; batch 1: `H7HYFDSX7.<lane>` from the read headers and tar member names; empty = derived from the Novogene lane file names (`<...>_<flowcell>_L<lane>_1.fq.gz`) |

All samples of one library must agree on `source`, `barcode_layout`, `raw_location`, `raw_r1`, `raw_r2` and `rg_pu` (checked by
build_samples.py and again when the library is read). Batch-1 tar members must pair as the R1 / R2 of one lane
(`<name>_R1_<nnn>.fastq.gz` / `<name>_R2_<nnn>.fastq.gz`, in the same order); the lane is named `<name>` (e.g. `BZea5_S5_L001`).

### `--registry`: meta/registry.csv

The sample-identity registry (every sequenced sample of every experiment, 52 columns; `meta/PROVENANCE.md`), built by the same
`meta/build_samples.py`. Read as text for the provenance record's registry snapshot (docs/output.md); its row of a sample must
agree with `--input` on `source` and `library`. A sample without a registry row gets `row` null and a note.

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

Profiles: `hazel,stub` (Gate 0, `-stub`), `hazel,short` (gates, 1 h cap), `hazel,normal` (Gate 2 and later; 24 h limit, each
task on short QOS when it asks <= 1 h 45, else on compute/normal; head job `sbatch --qos=normal --partition=compute --time=3-00:00:00`), `hazel,local` (one allocation, per-task cap in `conf/local.config`). The conda prefixes are prebuilt by
`scripts/build_envs.sbatch` (an xfer job) and listed in `conf/env_prefixes.config`; no env is ever built at task time.
Resources are Nextflow directives (`conf/base.config` labels, per-process values in `conf/hazel.config`, per-sample times scaled
by the task's input size; routing in `conf/normal.config`)
that the scripts read as `task.cpus` / `task.memory`; a resource change does not rerun cached tasks (Nextflow 26.04.6 does
not hash those values). `scripts/check_resources.sh` checks what each process resolves to (`tests/expected_resources.tsv`).
The head job's log starts with the checkout (`ZG_REPO`, default `ZEAL/zealgt`) and its commit; every Nextflow line carries a
timestamp.

### Store rules

- `--store` (default `ZEAL/store`) is the permanent store root. Outputs are copied in by `publishDir` (`overwrite: false`: a
  stored file is never replaced) and the workflow skips work whose stored output exists, whatever changed (no `storeDir`):
  a sample whose CRAM is stored is not aligned (or imported) again, a library with a stored demux QC table gets no DEMUX_QC and
  one with a registry entry no REGISTRY, stored QC files and provenance records are not made again (missing ones are).
- A CRAM counts as stored only if the CRAM and its `.crai` exist and the CRAM ends with the CRAM 3 EOF container. A sample with
  an unverified CRAM (e.g. a copy cut short by a killed head job), or with files left over without its CRAM, stops the run
  before any task, naming the files to check and remove by hand.
- `--subsample N` (Gate 1) needs a store **and** a checkpoint directory named `subsample_<N>`, e.g. `--store
  ZEAL/store/subsample_1000000 --fastq_checkpoint /share/maize/frodrig4/fastq_checkpoint/subsample_1000000`, so a subset never
  lands where the real CRAMs or FASTQs go; a `subsample_*` directory without `--subsample` is refused too, and
  `read_alignment` refuses a checkpoint written with another `--subsample`.
  N is read pairs per library: DEMUX runs once per library x lane, and each of the library's lanes gives its first
  ceil(N / lanes) pairs (the total is N rounded up to a multiple of the lane count).
- Stub runs need a store inside a directory named `store_stub*` outside `ZEAL/store` and a checkpoint inside `checkpoint_stub*`
  outside `/share/maize/frodrig4/fastq_checkpoint`; `-profile stub` sets `<outdir>/store_stub` and `<outdir>/checkpoint_stub`. On hazel the
  outdir is on `/rsstu`, so a stub run passes `--fastq_checkpoint /share/maize/frodrig4/nf_work/<run_id>/checkpoint_stub`.
- A library in the registry (`assets/registry_seed.csv` or `<store>/registry/<lib>.registry.tsv`) is refused unless named with
  `--force_demux <lib>`.
- `--max_libraries N` (default 4) bounds the libraries whose FASTQs a run leaves on `/share` (nothing is removed automatically:
  `work/` keeps every library of the run, the checkpoint keeps each library until the user removes it). `read_demultiplexing` is
  refused before any task when the requested libraries plus the libraries that already have a directory under
  `--fastq_checkpoint` (not counting `subsample_*` / `checkpoint_stub*` dirs) are more than N; the error lists those libraries
  with their `cleanup_status.tsv`. Remove a checkpoint only with the user's consent, once its report says removable. The
  requested libraries then all run concurrently (no `maxForks`). `read_alignment` adds no library and is not bounded.

### Waves of libraries (Gate 3) and the cleanup file

The full run (Gate 3, docs/PLAN_pipeline.md §6) is a series of **waves**: one `read_demultiplexing` run of at most
`--max_libraries` libraries each, with its own `--run_id` (e.g. `bc1_w01`, `bc1_w02`, ...), so its scratch dir, launch dir and
cleanup file are its own. Between two waves:

1. Wait for the wave's head job to end; check its log for failed tasks and the `zealgt: checkpoint <dir>: removable` /
   `keep:` lines (one per library).
2. Read `<outdir>/pipeline_info/cleanup_<run_id>.sh` (also printed at the end of the log). Its active lines only list and
   measure: `bash <file>` (or the lines one by one) shows each removable library's checkpoint dir and the wave's DEMUX,
   MERGE_LANES, TRIMMOMATIC and FASTQC task dirs with sizes and file counts, to compare with the numbers the pipeline wrote.
   On hazel `ls` / `du` / `find` over ssh are fine; a `nextflow clean` goes through a short-QOS job (hazel-debug-loop skill).
3. **With the user's explicit consent** for that wave, uncomment (or copy) the `# rm -r -- ...` lines under `# CONSENT:` for
   the removable libraries — or, if every library of the wave is removable, use the `nextflow clean -n` / `-f <run name>`
   alternative at the end of the file for all of the wave's `work/` plus the per-library checkpoint lines. Libraries marked
   `keep: k of n CRAMs missing` get no removal line: fix and rerun them (`-resume` of that wave, or `--entry
   read_alignment --libraries <lib>` from their checkpoint) before cleaning them.
4. Start the next wave. Its guard counts the checkpoint dirs still present (step 3 removed the finished ones), so a wave whose
   libraries were not cleaned leaves less room: the next request is refused with the list of those libraries.

Removing a library's checkpoint and stage-1 task dirs is final for its FASTQs: its CRAMs stay in the store (skipped as
stored), but `read_alignment` can no longer rerun it and demultiplexing it again needs `--force_demux` (registered).
The cleanup file lists the task dirs whose outputs the wave used (cached ones included); failed or retried attempts are not
listed (`nextflow log <run name> -f name,status,workdir` in the launch dir shows them; `nextflow clean` removes them too).

## Testing

`-profile test` runs `read_demultiplexing` on the fixture library LIBX (tests/fixtures: 3 samples, 940 read pairs, a tiny
reference with its minibwa index), with the store and the checkpoint under the outdir; `--entry read_alignment` with the same
`--fastq_checkpoint` reruns stage 2 alone. `-profile test,stub -stub` checks the wiring without tools. nf-test runs the module,
subworkflow and pipeline stub tests (the three entries, a `--max_libraries 1` request refused because another library holds a
checkpoint, and a two-library `--max_libraries 2` run); `scripts/run_checks.sh` runs everything before a push
(docs/CONTRIBUTING.md). The cache test `scripts/test_cache.sh` is a separate operator script (see the deviations below).

## Deliberate deviations from the nf-core specifications

Deliberate deviations from the nf-core specifications. The same list, word for word, is in `.nf-core.yml`, `docs/usage.md`,
`docs/PLAN_pipeline.md` §2 and the nfcore-compliance skill; a new deviation goes into all four, with its reason.
- **No containers** (spec: Docker / Singularity support). Hazel compute nodes are offline and run no container engine for
  this project; every module has a pinned `environment.yml` instead. The template's container configs
  (`conf/containers_*.config`) are removed and gitignored (`nf-core modules install/patch` regenerates them), and the
  `container_configs` lint test is off.
- **No GitHub Actions CI** (spec: CI testing). The pipeline runs on a private offline cluster; `scripts/run_checks.sh` runs
  the same checks on the laptop before every push (nf-core lint, schema lint, nextflow lint, nf-test, the env prefix and
  resolved-resource checks; docs/CONTRIBUTING.md).
- **Build-pinned conda prefixes set per process in the site config** (spec: conda packages pinned by version, envs created
  by Nextflow). `conf/env_prefixes.config`, generated by `scripts/build_envs.sh --write-config` and included by the hazel
  and local profiles only, sets each process's `conda` to a prebuilt prefix on `/share` (config `conda` overriding the
  module's, the standard Nextflow override). A prefix is keyed on the content of `environment.yml` (+ `build.sh`) only, so
  identical envs share one prefix; local modules pin version and build (linux-64 is the only target); the prefixes are built
  once by an xfer job (compute nodes are offline), never at task time.
- **Cache test as an operator script, not an nf-test** (spec: tests are nf-test). `scripts/test_cache.sh` resumes one
  Nextflow session across several runs (raised resources, an edited module, stage 2 alone) and compares the task hashes; nf-
  test starts a new session for every run and cannot share one.
- **Permanent store and FASTQ checkpoint outside `--outdir`** (spec: outputs published to `--outdir`). CRAMs, QC,
  provenance, demux QC and the registry are copied into `--store` (never overwritten) and the workflow skips work whose
  stored output exists; the trimmed pairs are hardlinked into `--fastq_checkpoint` (the filesystem of `work/`), with
  TRIMMOMATIC's small trim reports (one `publishDir` map: a second one whose path uses `meta` breaks `nextflow config -o
  json`, so nf-core lint). Only reports go to `--outdir`.
- **`versions.yml` files for five local modules** (spec: versions as `eval` topic tuples). ALIGN_MARKDUP and MARKDUP_IMPORT
  publish theirs next to the CRAM, one line per tool of the pipe, because PROVENANCE of an already stored CRAM (skipped, not
  made again) needs the versions of the tools that made it; DEMUX_QC, PROVENANCE and REGISTRY are python module templates,
  and Nextflow allows `eval` outputs only with Bash scripts. DEMUX and the nf-core modules report `eval` topic tuples;
  coreutils (DEMUX's `head`, MERGE_LANES's `cat`) is pinned in `environment.yml` but not reported (the BSD tools of the
  laptop's local runs have no `--version`).
- **Stage-2 samplesheet written by the pipeline** (spec: inputs through `--input`).
  `<fastq_checkpoint>/<lib>/samplesheet.csv` is an output of stage 1 and the only input of `--entry read_alignment`,
  validated by nf-schema against `assets/schema_checkpoint.json`.
- **`--subsample` / `--max_libraries` typed integer-or-string** (spec: typed parameters). Nextflow 26 hands CLI values over
  as strings; the schema accepts digit strings and the code converts.
- **Per-source read structures as two parameters** (`read_structure_*`, chosen by `barcode_layout`), not one per sample;
  both values are recorded in every provenance record.
- **CRAM output only, no `--bam`**: the genotype workflow reads CRAM.
