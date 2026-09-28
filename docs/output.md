# sawers-rellan-labs/zealgt: Output

## Introduction

The CRAM workflow writes its costly, reusable outputs into the **store** (`--store`, a Nextflow `storeDir` root on /rsstu) and
only QC reports into the results directory (`--outdir`). A stored output is never recomputed (docs/PLAN_pipeline.md §2, §5).

## Store (`--store`)

| path | written by | files |
|---|---|---|
| `demux_qc/` | DEMUX_QC (storeDir) | `<lib>.tsv` (per sample: barcodes, read pairs, share of input), `<lib>.summary.tsv` (input / assigned / unassigned pairs, assignment rate, samples with 0 pairs, lanes), `<lib>.read_start.tsv` (base composition of the first positions and TruSeq read-through share per sample and read), `<lib>.cutadapt.{json,log}` (the lane reports: DEMUX runs per library x lane; the JSON holds the summed input pairs and every lane report), `<lib>.demux_qc.versions.yml` |
| `cram/` | ALIGN_MARKDUP, PROVENANCE (storeDir); SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS (published) | `<sample>.cram` + `.cram.crai` (duplicates flagged, not removed; RG on every record; no MAPQ filter), `<sample>.markdup.stats`, `<sample>.align_markdup.versions.yml`, `<sample>.stats`, `<sample>.CollectWgsMetrics.coverage_metrics`, `<sample>.provenance.json`, `<sample>.provenance.versions.yml` |
| `cram_import/` | MARKDUP_IMPORT, PROVENANCE (storeDir); SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS (published) | as `cram/`, with `<sample>.markdup_import.versions.yml` and `<sample>.read_group.txt` (which read group was applied and why) |
| `registry/` | REGISTRY (storeDir) | `<lib>.registry.tsv`: one row per sample (demux read pairs, CRAM bytes, store, subsample, run id, code version, time); written only when every CRAM of the library is stored |

A `--subsample N` run writes the same layout into its own store named `subsample_<N>`; a stub run into `store_stub*`.

### Provenance record (`<sample>.provenance.json`, schema `zealgt.provenance/1`)

Run settings (`reference`, `code_version` = git commit of the checkout, `-dirty` if modified; `pipeline`, `entry`, `run_id`,
`run_name`, `session_id`, `profile`, `mapq_filter`, `markdup`), the sample (`sample`, `library`, `source`, `role`, `donor`,
`store_dir`, `read_group`), its `origin` (demux: raw location and files, tar members, cutadapt args, read structure, layout,
barcodes, subsample; import: input path, maker, input filters), for demultiplexed samples `trimming` and `alignment` settings
and `session_tool_versions` (DEMUX, TRIMMOMATIC and FASTQC versions of the session), and, added by the module, `cram_file`,
`cram_bytes`, `tool_versions_yml` (the versions.yml of the steps that made the CRAM), `record_written_utc`.

## Results directory (`--outdir`)

- `multiqc/<library>_multiqc_report.html` (+ `_data/`, `_plots/`): one report per library (per import set for
  `markdup_import`): cutadapt, Trimmomatic, FastQC, samtools stats / markdup, Picard.
- `trimmomatic/<library>/`: `<sample>.summary`, `<sample>_out.log` (the per-read trim log stays in work/).
- `fastqc/<library>/`: FastQC reports of the trimmed reads.
- `pipeline_info/`: Nextflow execution report, timeline, trace, DAG, `params_*.json`, and
  `zealgt_software_mqc_versions.yml` (every tool version of the run).

## Genotype workflow (`--workflow genotype`)

The genotype workflow reads `--cram_store` and never writes there. Its reusable outputs go into the keyed genotype store
`<store>/genotype/<genotype_store_key>/` (storeDir). Each `--entry` writes its own kinds, and the next entry reads them
(`--input_store_key` points it at another key). `<region>` is the region label (`chr10`, `chr10_1-20000000`), and `<set>` is
`--donor_set`.

### Genotype store (`<store>/genotype/<key>/`)

| path | entry (process) | files |
|---|---|---|
| `settings/<stage>.json` | every entry, at initialisation | the stage's parameters (reference tables and priors with sha256), `input_store_key`, the sha256 of each stage module's `main.nf` + templates and of the stage subworkflow, `workflows/genotype.nf` and `conf/genotype_modules.config`, and per unit the sample rows (`id\|role\|donor\|store_dir\|mask\|origin`); a rerun under the key must match (review #7) |
| `sample_qc/` | sample_quality_control (SAMPLE_QC_TABLE) | `sample_qc.tsv`: sample role donor **pass** reasons notes mean_coverage pct_1x panel_qc panel_min_covered panel_contigs_below_floor kinship_own own_z closest_other_donor kinship_closest_other relatedness_reason donor_content donor_content_reason (+ `min_coverage.tsv`, and with `--qc_panel` `panel_coverage.tsv`, `relatedness.tsv`, `donor_content.tsv`) |
| `step4/` | variant_discovery (POOLED_LIKELIHOOD_TIERS) | `<donor>.<region>.sites.tsv.gz`: chrom pos ref alt n a n_pools n_pools_alt eps n0 a0 self_in_zero LLR logodds posterior tier flags [in_<annotation> …] pool_counts (tiers A / B / C / ref; LLR and logodds at full precision); `.summary.tsv` (tier counts, tier × annotation), `.pool_qc.tsv`, `.run_info.txt`, versions.yml |
| `ancestry/` | ancestry_inference (RTIGER, LINE_MARKER_QC) | `<donor>.<region>.segments.csv`: source donor name chr start_bp end_bp state (x = 0 / 1 / 2 donor copies); `.line_qc.tsv`: sample contig markers markers_kept covered reads mean_depth floor contig_pass line_pass reason (a line below `min_markers_factor × rigidity` covered own tier-A markers is excluded from every later caller) |
| `union/` | marker_union (MARKER_UNION) | `<set>.<region>.tsv.gz`: chrom pos ref alt n_donors donors multiallelic donor_kind ref_donors; `.union_sites.tsv` (the non-multiallelic site list of the stage-6 counts); `.per_donor.tsv` (tier A, shared, private, n_gaps per donor, run and reference donors) |
| `joint_step4/<set>/` | donor_allele_calling (JOINT_POOLED_LIKELIHOOD) | `<donor>.<region>.sites.tsv.gz`: the step-4 columns re-scored on the union sites from one joint count |
| `gap_bc1/` | donor_allele_calling (GAP_FILLING_BC1, step 1) | `<set>.<region>.tsv.gz`: per donor and gap: src tier LLR k m prior logodds state flags |
| `gap_lines/<set>/` | donor_allele_calling (GAP_FILLING_LINES, step 2) | `<donor>.<region>.tsv.gz`: chrom pos ref alt prior llr_bc1 llr_lines logodds_combined call (ALT \| undecided \| blocked_flag \| blocked_b73_lines \| no_test) eps_s eps0 n0 a0 n0_lines a0_lines …; summary with the ALT-read rate in x = 0 lines at the calls (review #3) |
| `donor_alleles/<set>/` | donor_allele_calling (DONOR_FOUNDER) | `<donor>.<region>.tsv.gz`: chrom pos ref alt D (ALT \| REF \| NA) call_step (own \| step1_ref \| step1_alt \| step2_alt \| missing \| multiallelic) logodds p_alt; `.summary.tsv` (step-1 and step-2 shares reported separately, review #2) |
| `genotypes/<set>/` | genotype_imputation (RASTERIZE) | `<donor>.<region>.tsv.gz` long: line chrom pos ref alt x D gt dosage_expected (gt = x if D = ALT, 0 if REF, NA if D is missing and x > 0, NA where the ancestry is unknown or the line excluded; dosage_expected = x · P(ALT), review #9); `.matrix.tsv.gz` wide (sites × lines) |

### Results directory (genotype)

- The store tables above are also published under `--outdir`, per stage.
- variant_discovery publishes the CRISP raw, BED-clipped and vetoed VCFs, the witness-veto summary, the B73 counts and the
  CRISP log.
- reporting publishes:
  - `genotype_summary.tsv`: per line, Mb REF / HET / ALT and the no-call share;
  - `single_locus.tsv`: allele and genotype frequencies against the `--reporting_expectation`, by default BC2S2 (HET 1/16,
    TEO 3/32);
  - `breakpoint_density.tsv`: step-2 calls near RTIGER breakpoints versus elsewhere (review #12);
  - `read_position_qc.tsv`: the ALT / other fraction by read cycle, per role, before and after the 5′ mask;
  - `<id>.painting.png` / `.pdf`: chromosome paintings.
- `pipeline_info/` is written as for the CRAM workflow.
