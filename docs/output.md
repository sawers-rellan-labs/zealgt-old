# sawers-rellan-labs/zealgt: Output

## Introduction

The CRAM workflow writes its costly, reusable outputs into the **store** (`--store`, on /rsstu), its trimmed FASTQs into the
**FASTQ checkpoint** (`--fastq_checkpoint`, on the `work/` filesystem) and only QC reports into the results directory
(`--outdir`). Store files are published by copy and never overwritten; the workflow skips work whose stored output exists
(docs/PLAN_pipeline.md §2, §5; docs/usage.md "Store rules").

## Store (`--store`)

| path | written by | files |
|---|---|---|
| `demux_qc/` | DEMUX_QC | `<lib>.tsv` (per sample: barcodes, read pairs, share of input), `<lib>.summary.tsv` (input / assigned / unassigned pairs, assignment rate, samples with 0 pairs, lanes), `<lib>.read_start.tsv` (base composition of the first positions and TruSeq read-through share per sample and read), `<lib>.cutadapt.{json,log}` (the lane reports: DEMUX runs per library x lane; the JSON holds the summed input pairs and every lane report), `<lib>.demux_qc.versions.yml` |
| `cram/` | ALIGN_MARKDUP, SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS, PROVENANCE | `<sample>.cram` + `.cram.crai` (duplicates flagged, not removed; RG on every record; no MAPQ filter), `<sample>.markdup.stats`, `<sample>.align_markdup.versions.yml`, `<sample>.stats`, `<sample>.CollectWgsMetrics.coverage_metrics`, `<sample>.provenance.json`, `<sample>.provenance.versions.yml` |
| `cram_import/` | MARKDUP_IMPORT, SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS, PROVENANCE | as `cram/`, with `<sample>.markdup_import.versions.yml` and `<sample>.read_group.txt` (which read group was applied and why) |
| `registry/` | REGISTRY | `<lib>.registry.tsv`: one row per sample (demux read pairs, CRAM bytes, store, subsample, run id, code version, time); written only when the demux QC table and every CRAM of the library are there |

A CRAM counts as stored only with its `.crai` and the CRAM 3 EOF container at its end. A `--subsample N` run writes the same
layout into its own store named `subsample_<N>`; a stub run into `store_stub*`.

### Provenance record (`<sample>.provenance.json`, schema `zealgt.provenance/1`)

Run settings (`reference`, `code_version` = git commit of the checkout, `-dirty` if modified; `pipeline`, `entry`, `run_id`,
`session_id`, `profile`, `mapq_filter`, `markdup`; no Nextflow run name: the record is a hashed task input, and a name that
changes per launch would rerun PROVENANCE on every `-resume`), the sample (`sample`, `library`, `source`, `role`, `donor`,
`store_dir`, `read_group`), the registry snapshot `registry` (meta/PROVENANCE.md "Identifiers": `file` = the `--registry`,
relative to the pipeline directory when inside it, e.g. `meta/registry.csv`; `code_version` = the commit at which the row was read,
for demultiplexed samples the stage-1 commit; `row` = the sample's raw identity and biology columns as the sources give them, as
strings in the registry's spelling (`sample_id`, `source`, `role`, `library`, `plate`, `well`, `lab_seq_id`, `delivered_name`,
`accession`, `taxa_code`, `taxon`, `donor`, `line_id`, `old_line_id`, `pedigree`, `nil_id`, `nil_id_in_register`, `is_check`, the
J2Teo generation columns `gen` … `TC`, `j2teo_batch`, `j2teo_seed_origin`, `field`, `field_plot`, `seed_packet`, `mother_plant`,
`replicate_of`, `exclude`, `exclude_reason`, `flags`); `resolved` = `pedigree_resolved`, `nil_id_resolved`, `donor_resolved`,
`correction_ids` (meta/corrections.csv applied), kept apart so they never replace a raw value; `note`; a sample not in the registry
has `row` and `resolved` null and a note), its `origin` (demux: raw location and files, tar
members, cutadapt args, read structure, layout, barcodes, subsample, the checkpoint FASTQs `fastq_checkpoint`, and the stage-1
run `stage1_run_id`, `stage1_session_id`, `stage1_code_version`, `stage1_tool_versions` (DEMUX and CUTADAPT tool versions, keyed `PROCESS.tool`);
import: input path, maker, input filters, and `import_sheet_row`, the import sheet's row as strings), for demultiplexed samples `trimming` (`tool`, `adapter_r1`, `adapter_r2`, `args`) and `alignment` settings, and, added by the module, `cram_file`, `cram_bytes`,
`tool_versions_yml` (the versions.yml of the steps that made the CRAM), `record_written_utc`. `read_demultiplexing` (stage 2
chained) and `read_alignment` (stage 2 alone) build the record from the same checkpoint row, so for one sample the two differ
only in the run fields (the registry snapshot is identical). No line or nil id is written into a CRAM header: the read group is
`ID` = `SM` = `sample_id`, one per sample.

## FASTQ checkpoint (`--fastq_checkpoint`)

| path | written by | files |
|---|---|---|
| `<lib>/` | CUTADAPT (`publishDir` mode `link`: hardlinks of the `work/` files) | `<sample>_1.trim.fastq.gz`, `<sample>_2.trim.fastq.gz`, and the cutadapt log `<sample>.cutadapt.log` (also in MultiQC) |
| `<lib>/samplesheet.csv` | the CRAM workflow, once every sample of the library is trimmed | one row per sample, everything stage 2 needs (columns in docs/usage.md; `assets/schema_checkpoint.json`); the input of `--entry read_alignment` |
| `<lib>/cleanup_status.tsv` | every run with stage 2 (at its end) | per sample `sample`, `cram`, `cram_bytes`, `verified` (yes/no), `fastq_1`, `fastq_1_bytes`, `fastq_2`, `fastq_2_bytes`; last line `# checkpoint <dir>: removable (N files, X GB) — remove only with the user's consent` or `# checkpoint <dir>: keep: k of n CRAMs missing` (also in the log) |

Nothing is removed by the pipeline. Every `<lib>/` directory counts against `--max_libraries` until it is removed (with the
user's consent, once `cleanup_status.tsv` says removable, using the commands in `<outdir>/pipeline_info/cleanup_*.sh`;
docs/usage.md "Store rules" and "Waves of libraries"). The cutadapt logs live here, not in
`--outdir` (one `publishDir` per process: docs/usage.md "Deliberate deviations"). A `--subsample N` run uses a checkpoint named
`subsample_<N>`; a stub run `checkpoint_stub*`.

## Results directory (`--outdir`)

- `multiqc/<library>_multiqc_report.html` (+ `_data/`, `_plots/`): one report per library (per import set for
  `markdup_import`): cutadapt (demultiplexing and trimming), FastQC, samtools stats / markdup, Picard (`read_alignment`: the stage-2 reports only).
- `fastqc/<library>/`: FastQC reports of the trimmed reads.
- `pipeline_info/`: Nextflow execution report, timeline, trace, DAG, `params_*.json`, and
  `zealgt_software_mqc_versions.yml` (every tool version of the run).
- `pipeline_info/cleanup_<run_id or session id>.sh` (runs with stage 2: `read_demultiplexing`, `read_alignment`; written at the
  end of the run, success or failure, and printed in the log; a `-resume` with the same run id or session rewrites it):
  **cleanup commands for the user, never run by the pipeline**. It starts with a header saying so (read the whole file before
  using any line). Per library of the run:
  - *removable* (every CRAM stored and verified, as in `cleanup_status.tsv`): the checkpoint dir with its size and file count, then
    the run's `work/` task dirs that hold the library's FASTQs (DEMUX, MERGE_LANES, CUTADAPT, FASTQC; each with process, path,
    file count, size and hardlinked bytes, measured at the end of the run), as active listing lines (`ls -la`, `du -sh`,
    `find -maxdepth … ! -type d | wc -l`, `cat cleanup_status.tsv`), followed by one `# rm -r -- '<path>'` line per task dir and
    one for the checkpoint dir, **commented out** under a `# CONSENT:` line. A `read_alignment` run has no stage-1 task dirs;
    the file names the stage-1 session whose own cleanup file lists them.
  - *keep*: `# ==== library <lib>: keep: k of n CRAMs missing; no removal line ====` (or `keep: no samplesheet.csv`).
  - At the end, a `nextflow clean -n <run name>` / `# CONSENT: nextflow clean -f <run name>` alternative (whole run, every task
    dir, never the checkpoint), offered only when every library of the run is removable.

  The task dirs are those whose outputs the run used (cached ones included); failed or retried attempts are not listed (the file
  says how to list them with `nextflow log`). Running the file unchanged only lists and measures.

## Genotype workflow (`--workflow genotype`)

The genotype workflow reads `--cram_store` and never writes there. Its reusable outputs go into the keyed genotype store
`<store>/genotype/<genotype_store_key>/` (storeDir). Each `--entry` writes its own kinds, and the next entry reads them
(`--input_store_key` points it at another key). `<region>` is the region label (`chr10`, `chr10_1-20000000`), and `<set>` is
`--donor_set`.

**Identifiers** (meta/PROVENANCE.md "Identifiers: one physical key, biology in the registry"): every store table, every
internal table and every QC table (`sample_qc.tsv`, `line_qc.tsv`, `read_position_qc.tsv`, the VCF pool names) is keyed by the
well-level `sample_id`. Only the **final reporting outputs** carry the short id: SAMPLE_LABELS joins the `sample_id` once on
the current registry (`--registry`, default `meta/registry.csv`) and labels each sample with its `nil_id_resolved`, else its
`pedigree_resolved` (line id, e.g. BC1 samples), else its `sample_id` (the B73 controls have no registry row). Only the
resolved columns are read (`meta/corrections.csv` applied by `meta/build_samples.py`), and a registry row with `exclude` = TRUE
is refused. Replicate wells that share a
`nil_id` in one unit are labelled `<nil_id>_<sample_id>` and listed in the `collision` column of `sample_labels.tsv`.

### Genotype store (`<store>/genotype/<key>/`)

| path | entry (process) | files |
|---|---|---|
| `settings/<stage>.json` | every entry, at initialisation | the stage's parameters (reference tables and priors with sha256), `input_store_key`, the sha256 of each stage module's `main.nf` + templates and of the stage subworkflow, `workflows/genotype.nf` and `conf/genotype_modules.config`, and per unit the sample rows (`id\|role\|donor\|store_dir\|mask\|origin`); a rerun under the key must match (review #7) |
| `sample_qc/` | sample_quality_control (SAMPLE_QC_TABLE) | `sample_qc.tsv`: sample role donor **pass** reasons notes mean_coverage pct_1x panel_qc panel_min_covered panel_contigs_below_floor kinship_own own_z closest_other_donor kinship_closest_other relatedness_reason donor_content donor_content_reason (+ `min_coverage.tsv`, and with `--qc_panel` `panel_coverage.tsv`, `relatedness.tsv`, `donor_content.tsv`) |
| `step4/` | variant_discovery (POOLED_LIKELIHOOD_TIERS) | `<donor>.<region>.sites.tsv.gz`: chrom pos ref alt n a n_pools n_pools_alt eps n0 a0 self_in_zero LLR logodds posterior tier flags [in_<annotation> …] pool_counts (tiers A / B / C / ref; LLR and logodds at full precision); `.summary.tsv` (tier counts, tier × annotation), `.pool_qc.tsv`, `.run_info.txt`, versions.yml |
| `ancestry/` | ancestry_inference (RTIGER, LINE_MARKER_QC) | `<donor>.<region>.segments.csv`: source donor name chr start_bp end_bp state (x = 0 / 1 / 2 donor copies); `.line_qc.tsv`: sample contig markers markers_kept covered reads mean_depth floor contig_pass line_pass reason (a line below `min_markers_factor × rigidity` covered own tier-A markers is excluded from every later caller); `.rigidity.txt`: the unit's effective rigidity (`rigidity` at `rigidity_ref_markers` markers per chromosome, scaled to the unit's marker density) |
| `union/` | marker_union (MARKER_UNION) | `<set>.<region>.tsv.gz`: chrom pos ref alt n_donors donors multiallelic donor_kind ref_donors; `.union_sites.tsv` (the non-multiallelic site list of the stage-6 counts); `.per_donor.tsv` (tier A, shared, private, n_gaps per donor, run and reference donors) |
| `joint_step4/<set>/` | donor_allele_calling (JOINT_POOLED_LIKELIHOOD) | `<donor>.<region>.sites.tsv.gz`: the step-4 columns re-scored on the union sites from one joint count |
| `gap_bc1/` | donor_allele_calling (GAP_FILLING_BC1, step 1) | `<set>.<region>.tsv.gz`: per donor and gap: src tier LLR k m prior logodds state flags |
| `gap_lines/<set>/` | donor_allele_calling (GAP_FILLING_LINES, step 2) | `<donor>.<region>.tsv.gz`: chrom pos ref alt prior llr_bc1 llr_lines logodds_combined call (ALT \| undecided \| blocked_flag \| blocked_b73_lines \| no_test) eps_s eps0 n0 a0 n0_lines a0_lines …; summary with the ALT-read rate in x = 0 lines at the calls (review #3) |
| `donor_alleles/<set>/` | donor_allele_calling (DONOR_FOUNDER) | `<donor>.<region>.tsv.gz`: chrom pos ref alt D (ALT \| REF \| NA) call_step (own \| step1_ref \| step1_alt \| step2_alt \| missing \| multiallelic) logodds p_alt; `.summary.tsv` (step-1 and step-2 shares reported separately, review #2) |
| `genotypes/<set>/` | genotype_imputation (RASTERIZE) | `<donor>.<region>.genotypes.tsv.gz` long: line (= sample_id) chrom pos ref alt x D gt dosage_expected (gt = x if D = ALT, 0 if REF, NA if D is missing and x > 0, NA where the ancestry is unknown or the line excluded; dosage_expected = x · P(ALT), review #9); `.genotypes.matrix.tsv.gz` wide (sites × lines) |

### Results directory (genotype)

- The store tables above are also published under `--outdir`, per stage.
- variant_discovery publishes the CRISP raw, BED-clipped and vetoed VCFs, the witness-veto summary, the B73 counts and the
  CRISP log.
- reporting publishes (`<outdir>/genotype/<key>/reporting/<set>/`, per unit `<donor>.<region>`; the lines are named by the
  label, see **Identifiers**):
  - `<unit>.genotypes.tsv.gz` (long: line sample_id chrom pos ref alt x D gt dosage_expected, line = label) and
    `<unit>.genotypes.matrix.tsv.gz` (sites × labels): the final genotype tables;
  - `<unit>.sample_labels.tsv`: sample_id label label_source (nil_id \| pedigree \| sample_id_not_in_registry \|
    sample_id_no_label) collision nil_id pedigree donor (the resolved values) taxon role correction_ids registry
    registry_sha256 code_version, one row per sample
    of the unit (the donor's sheet samples, the B73 controls, and every id in the tables); `registry_sha256` and
    `code_version` (the repo commit) record which registry the labels came from (recorded, not part of the settings guard);
  - `<unit>.exclusions.tsv`: sample (label) sample_id role stage reason, every sample dropped at stage 2b or 4;
  - `genotype_summary.tsv`: per line, Mb REF / HET / ALT and the no-call share;
  - `single_locus.tsv`: allele and genotype frequencies against the `--reporting_expectation`, by default BC2S2 (HET 1/16,
    TEO 3/32);
  - `breakpoint_density.tsv`: step-2 calls near RTIGER breakpoints versus elsewhere (review #12);
  - `read_position_qc.tsv`: the ALT / other fraction by read cycle, per role, before and after the 5′ mask (QC: sample_id);
  - `<id>.painting.png` / `.pdf`: chromosome paintings (bars named by the label).
- `pipeline_info/` is written as for the CRAM workflow.
