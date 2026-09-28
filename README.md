# zealgt

Genotyping pipeline for the ZEAL population (teosinte × B73 BC₂S₃ near-isogenic lines): from pooled BC1 libraries and BC₂S₃ skims to
per-line **ancestry** (RTIGER) and **imputed genotypes** at the union of informative sites (pairwise PHG), for QTL mapping and GWAS.

Successor of the exploratory work in `zealbc1` (chr10 pilots, 2026-09-10 → 24). Code and data are separate: this repo is code and docs;
data and results live on the BZea partition on hazel.

## Quick start
A Nextflow pipeline built on the nf-core template (deliberate deviations in `docs/usage.md`). On hazel, through the head job
(never the login node; `.claude/skills/hazel-debug-loop`):

```bash
# raw library -> CRAMs + QC + provenance + registry entry, into the store
sbatch scripts/submit_head_job.sbatch <run_id> -profile hazel,short --entry read_demultiplexing --libraries <lib> --outdir <results>
# existing CRAMs (meta/dev_import.csv) -> duplicate marking + read groups
sbatch scripts/submit_head_job.sbatch <run_id> -profile hazel,short --entry markdup_import --import_samples <ids> --outdir <results>
```

Locally: `nextflow run . -profile test,stub -stub --outdir <dir>` (wiring), `bash scripts/run_checks.sh` (lint + nf-test, before
every push). Usage and outputs: `docs/usage.md`, `docs/output.md`.

## Documents
| file | what |
|---|---|
| `docs/PLAN_pipeline.md` | pipeline plan (draft): stages as Nextflow entries, caching/rerun rules, storage and cleanup (from the 2026-09-24 disk audit), sample QC, known issues and open decisions |
| `docs/REQUIREMENTS.md` | requirements for a minimal run: inputs, software, measured compute per stage, hard-coded values to parameterize |
| `docs/math_supplement.tex` | mathematical supplement (draft): crossing scheme, BC1 pools vs BC₂S₃ bulks, reads at low coverage (λ), variant discovery, marker union and gap filling, ancestry inference and genotype imputation |
| `meta/samples.csv` | the single sample sheet of workflow 1 (2,283 samples: BC1, BC2S3 batches 1 and 2), built by `meta/build_samples.py`; provenance in `meta/PROVENANCE.md` |
| `docs/runs/` | one run card per run: purpose, donors (BC1 samples, lines, coverage), exclusions |

Build the supplement: `latexmk -pdf -outdir=build docs/math_supplement.tex`.
