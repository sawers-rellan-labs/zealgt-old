# sawers-rellan-labs/zealgt: Usage

> _Every parameter is documented in `nextflow_schema.json` (`nextflow run . --help --show_hidden`). This page explains how the
> pieces fit together._

## Introduction

zealgt has two workflows, chosen by `--workflow`, that meet only at the **store** (docs/PLAN_pipeline.md §3):

- `--workflow cram` (default): raw sequencing libraries -> analysis-ready CRAMs + QC + provenance + the demux registry.
- `--workflow genotype`: CRAM store -> sample QC, variant discovery, ancestry, marker union, donor alleles, genotypes,
  reports (seven entries, one stage each; section "Genotype workflow" below).

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
compute/normal), `hazel,local` (one allocation, explicit resources). The conda prefixes are prebuilt by
`scripts/build_envs.sbatch` (an xfer job) and listed in `conf/env_prefixes.config`; no env is ever built at task time.

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

## Genotype workflow

`--workflow genotype --entry <stage>` runs **one stage**. Its inputs are the CRAM store (read-only) and the outputs of the
earlier stages, which it reads from the keyed genotype store. A missing input stops the run at initialisation, and the
message names the entry to run first. `--workflow genotype` without `--entry` is refused, and so is a CRAM entry under it.

| # | entry | runs per | writes (`<store>/genotype/<genotype_store_key>/`) |
|---|---|---|---|
| 2b | `sample_quality_control` | cohort (the `--donors` rows + `--b73_controls`) | `sample_qc/sample_qc.tsv` (pass / fail per sample; every later stage drops failed samples) |
| 3 | `variant_discovery` | donor × region | `step4/<donor>.<region>.sites.tsv.gz` (+ summary, pool QC, run info) |
| 4 | `ancestry_inference` | donor × region | `ancestry/<donor>.<region>.segments.csv`, `.line_qc.tsv` |
| 5 | `marker_union` | donor set × region | `union/<set>.<region>.tsv.gz` (+ `.union_sites.tsv`, `.per_donor.tsv`) |
| 6 | `donor_allele_calling` | donor / set × region | `joint_step4/`, `gap_bc1/`, `gap_lines/`, `donor_alleles/<set>/<donor>.<region>.tsv.gz` |
| 7 | `genotype_imputation` | donor × region | `genotypes/<set>/<donor>.<region>.tsv.gz` (+ `.matrix.tsv.gz`) |
| 8 | `reporting` | donor × region | nothing in the store; tables and paintings in `--outdir` |

`<region>` is the region label: `chr10`, or `chr10_1-20000000` for `--regions chr10:1-20000000`.

### Inputs

- **Run card:** `-params-file docs/runs/<run>.yml`, with the narrative in `docs/runs/<run>.md`. It holds every parameter of the
  run. Required: `genotype_store_key`, `donors`, `regions`. From marker_union on, `donor_set` is required too, and
  donor_allele_calling also needs `mappability_priors`. Examples: `docs/runs/genotype_gate1_zx0540.yml` (Gate 1, every
  parameter explicit, with each open decision commented) and `docs/runs/gate0/genotype_gate0_<entry>.yml` (Gate 0 stubs).
- **`--genotype_input`:** the genotype sheet, `meta/genotype_dev.csv` (`assets/schema_genotype.json`, built by
  `meta/build_genotype_sheet.py`). Its columns are `sample_id` (no dots), `role` (`bc1_sample | line | b73_control`), `donor`
  (required unless `b73_control`), `taxon`, `source`, `store_dir` (`cram | cram_import`), `mask_r1`, `mask_r2` (5′ cycles set
  to Q0 by MASK_READ_STARTS, 0-30), `include` and `mask_source`. The sheet holds no paths. The workflow reads
  `<cram_store>/<store_dir>/<sample_id>.{cram, cram.crai, CollectWgsMetrics.coverage_metrics, provenance.json}` and checks at
  initialisation that they exist.
- **Reference inputs:**
  - `--fasta` (+ `.fai`) and `--lowcopy_bed` (currently chr10 only);
  - optionally `--qc_panel` (the blind panel does not exist yet) and `--annotation_panels name=path,...`;
  - `--reference_donor_tables donor=path,...`: read-only step-4 tables of donors not called in the run. They supply gaps
    and the prior's k / m in a single-donor run;
  - `--reference_donor_taxa donor=taxon,...`: the taxon of each reference donor (they are not in the sample sheet). With
    `--gap_prior_scope same_taxon` a reference donor stays in the step-1 prior only when its taxon equals the called
    donor's, so the run is refused when a reference donor has no taxon;
  - `--mappability_priors`: a directory of `<taxon>.prior.tsv` (columns `c weight`).

### Store rules (genotype)

- **Two stores:** `--cram_store` is where CRAMs, QC and provenance are read, and the genotype workflow never writes there.
  Genotype outputs go to `<store>/genotype/<genotype_store_key>/`.
- **Keyed settings (review #7):** on first use, each stage writes `settings/<stage>.json` with:
  - its parameters;
  - the sha256 of its modules' code;
  - the sample rows of every unit.

  A later run with the same key and different parameters, code or sample rows is refused, and the message lists each
  differing field. Use a new key, or `--input_store_key <old key>` to read upstream outputs from an older key. A module
  edit under an existing key is refused too, so develop under a fresh key.
- **Provenance:** each CRAM's `provenance.json` must record `markdup = samtools markdup ${markdup_args}`
  (`--provenance_check strict`, the default); `warn` only logs a mismatch.
- **Controls:** `--b73_controls` must name at least one `b73_control` row in a real run, because the controls are the zero
  class of step 4. An empty set is allowed only in a stub run.
- **Read-start masks:** `--mask_read_starts false` sets every mask to 0. The same code path runs.

### Running (hazel)

Submit one head job per entry, in stage order, each after the previous one has finished:

```bash
ssh hazel 'sbatch --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype \
    /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype/scripts/submit_head_job.sbatch <run_id> -profile hazel,short \
    -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype/docs/runs/<run>.yml --entry <entry>'
```

`ZG_REPO` points the head job at the checkout to run. The default is the CRAM checkout `ZEAL/zealgt`.

## Testing

`-profile test_genotype` runs the genotype workflow on `tests/fixtures/genotype`, which is written by
`tests/fixtures/genotype/make_fixtures.py` and is deterministic, with sha256s in its `MANIFEST.tsv`. The fixtures are:

- 8 synthetic CRAMs in a `cram_import` store (2 BC1 pools, 4 lines plus 1 below the coverage floor, 1 B73 control) on the
  reference slice `ref/tiny10.fa`;
- the lowcopy BED slice, panel, prior and a reference-donor step-4 table;
- `store_seed/`: every stage's store outputs under key `test`.

The run covers one donor (Zx.9001_P1) and one region (`chr10:1-16000`). `tests/genotype.nf.test` runs a stub of each entry,
seeding the store with the kinds of the stages before it, and checks four refusals: CRAM entry, missing upstream, changed
settings under the same key, and provenance mismatch.

`-profile test` runs `read_demultiplexing` on the fixture library LIBX (tests/fixtures: 3 samples, 940 read pairs, a tiny
reference with its minibwa index). `-profile test,stub -stub` checks the wiring without tools. nf-test runs the module,
subworkflow and pipeline stub tests; `scripts/run_checks.sh` runs everything before a push (docs/CONTRIBUTING.md).

## Deliberate deviations from the nf-core specifications

| deviation | why |
|---|---|
| Conda only, no containers; no `-profile docker` (M6) | hazel compute nodes are offline and run no container engine for this project; every module has a pinned `environment.yml` and a prebuilt prefix. The stale template container configs were removed (.nf-core.yml). |
| Build-pinned conda packages (M10) | linux-64 is the only target, and the hazel prefix is keyed by the sha of `environment.yml`; the pins are what was built and smoke-tested. |
| No GitHub Actions CI (P2) | private offline cluster; `scripts/run_checks.sh` runs the same checks locally before every push. |
| Resources read from Slurm at run time (M7, P16) | `${task.cpus}` / `${task.memory}` in a script change the task hash on every retry with more memory. Scripts `source export_slurm_resources.sh` (bin/, found on the task PATH by name, so no checkout path enters the hash); `conf/local.config` and `conf/test.config` give an explicit override. The four patched nf-core modules change resources only (plus the staged Trimmomatic adapters). |
| storeDir store, nothing published by default (P15) | CRAMs, demux QC, registry and provenance live in the store and are never recomputed; nf-core QC modules (with `eval` versions, which storeDir forbids) publish into the store instead. |
| Step-named local modules (M11) | `demux`, `demux_qc`, `align_markdup`, `markdup_import`, `provenance`, `registry` name pipeline steps; renaming a module directory renames its hazel conda prefix (rebuild). Each meta.yml names the tools it wraps. |
| One versions.yml per storeDir module (M3) | storeDir does not allow `eval` outputs; the yml lists every tool of the pipe. DEMUX (not storeDir'd) emits one topic tuple per tool. |
| Per-source read structures as two params (P17) | chosen by `barcode_layout`; both values are recorded in every provenance record. |
| `--subsample` / `--max_libraries` typed integer-or-string (P14) | Nextflow 26 hands CLI values over as strings; the schema accepts digit strings and the code converts. |
| CRAM output only, no `--bam` (P12) | the genotype workflow reads CRAM. |
| nf-core `bcftools/mpileup` not used (M1, genotype) | The nf-core module always pipes into `bcftools call` and reheaders to one sample (`sample_name.list` = `meta.id`). Every count in the genotype workflow needs raw multi-sample `AD` at fixed sites with no calling. The local `allele_counts` module runs `bcftools mpileup -I -a AD -T <sites> \| bcftools query`, with `-I` in the script because indel records would overwrite SNP counts (PLAN §4 #3). Patching the nf-core module would replace its whole script. `bcftools/view` is used (BED_CLIP), with a resource-only patch. |
| nf-core `samtools/merge` not used (M1, genotype) | The witness pool (about 40 line BAMs) is merged, given one read group and indexed in one pipe inside `witness_pool`, so the ~2 GB intermediate never reaches `work/` (PLAN §2 principle 5). |
| One shared python env for the python genotype modules (M8) | About 15 genotype modules call only `python3` with the standard library. They all run in the env of `pooled_likelihood_tiers` (python 3.12.14) through `envs/process_aliases.tsv`, as MERGE_LANES uses demux's env. This bundles no tools and saves about 14 conda prefixes on the group file quota. Each module's `meta.yml` names the owner env. |
