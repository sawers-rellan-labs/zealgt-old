# sawers-rellan-labs/zealgt: Output

## Introduction

The CRAM workflow writes its costly, reusable outputs into the **store** (`--store`, a Nextflow `storeDir` root on /rsstu) and
only QC reports into the results directory (`--outdir`). A stored output is never recomputed (docs/PLAN_pipeline.md §2, §5).

## Store (`--store`)

| path | written by | files |
|---|---|---|
| `demux_qc/` | DEMUX_QC (storeDir) | `<lib>.tsv` (per sample: barcodes, read pairs, share of input), `<lib>.summary.tsv` (input / assigned / unassigned pairs, assignment rate, samples with 0 pairs), `<lib>.read_start.tsv` (base composition of the first positions and TruSeq read-through share per sample and read), `<lib>.cutadapt.{json,log}`, `<lib>.demux_qc.versions.yml` |
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
