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
