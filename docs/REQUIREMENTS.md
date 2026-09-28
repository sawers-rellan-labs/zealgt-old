# zealgt — requirements for a minimal run (DRAFT, 2026-09-24)

What a run needs: input files, software, and compute. Today these are hard-coded in the chr10 pilot scripts (`PHG/bin/*.sbatch`,
`nilhmm/modules/*.nf`, `nilhmm/nextflow.config`); §5 lists them so zealgt can take them as parameters. Stage names follow
`docs/PLAN_pipeline.md`. Resource numbers are **measured** on hazel (chr10 pilots, 2026-09-17 → 24) unless marked *requested only*.

## 1. The minimal run
**One donor, one chromosome (chr10), all stages from its reads to ancestry and imputed genotypes.** For the marker union, a second donor
of the same taxon (the union and gap filling need ≥ 2 donors). This is the unit the pilot ran; the full run is this unit × donors ×
chromosomes, with only `marker_union` and the PHG database as barriers.

## 2. Inputs
| input | what | minimal run | current location (hazel) | used by |
|---|---|---|---|---|
| reference | B73 NAM v5 FASTA + `.fai` + minibwa index | whole genome (reads are aligned genome-wide) | `ZEAL/reference/B73.fa{,.fai,.mbw,.l2b}` | read_alignment, all pileups |
| chromosome reference | B73 chr10 FASTA for the PHG graph | chr10 | `results/phg_pilot/chr10/B73_chr10.fa` | genotype_imputation |
| reference ranges | lowcopy BED: gene ±500 bp ∪ non-TE intergenic, merged | chr10: 8,095 ranges, 26.0 Mb | `results/pilot_1B_chr10/union/union_chr10.bed` (built by `PHG/bin/make_union_bed.py` from the v5 gene GFF + `Zm-B73-REFERENCE-NAM-5.0.TE.gff3.gz`) | variant_discovery, PHG |
| BC1 raw libraries | inline-barcoded pool FASTQs (12 samples per library) | the libraries holding the donor's BC1 samples (1–5 libraries) | `BZea/BC1_dna_raw/01.RawData/BC1_<pool>` (115–150 GB each for pools 2A–2H) | read_demultiplexing |
| BC1 sample map | pool, column, barcode → Sample_Id → donor | the donor's rows | `meta/bc1_well_map.csv`, `meta/inline_barcodes.tsv` | read_demultiplexing, variant_discovery |
| BC2S3 reads, batch 1 (~0.4×) | trimmed per-line FASTQs | the donor's lines | `sara/BZea/filtered_S/filtered_S<plate>/<line>/` | read_alignment |
| BC2S3 reads, batch 2 (~1.2×) | row libraries (12 lines per row, inline barcodes) + well map | the rows holding the donor's lines | `BZea/BC2S3_batch_2_dna_raw/`, `meta/bc2s3_batch2_well_map.csv` (4 sequenced plates, 384 wells) | read_demultiplexing |
| line → donor | pedigree register | the donor's lines | zealhmm `register_bc2s3.csv`, `agent/skim_sample_nil_id.tsv` | all per-donor stages |
| B73 controls | NCBI B73 (ERR3288215, 15.5×) + B73 check pool (skim10, 5.7×) | both | `results/b73_control/{ERR3288215,skim10}/` | variant_discovery (step-4 zero class), donor_allele_calling |
| QC panel | lowcopy ∩ teosinte variants (wideseq), positions only | chr10 | to build (stage 2b) | sample_quality_control |
| annotation panels (optional) | TIL18/Gigi assembly SNPs, Schnable 2023, MaizeGDB 2026 positions | chr10 | `results/crisp_bench/*_vs_B73_chr10_snps.tsv`, `results/pilot_1B_chr10/panel_positions/` | step-4 annotation columns only (not used by the tiers) |
| run card | purpose, donors (BC1 count, lines, coverage), exclusions | one per run | `docs/runs/<run>.md` (new) | every entry |

## 3. Software
| tool | version / build | environment today |
|---|---|---|
| cutadapt | exact inline demux (`-e 0 --no-indels`) | `/share/maize/frodrig4/conda/env/assembly` |
| minibwa, samtools | `-x sr`; MAPQ 20, `-F 0x904` | `.../conda/env/assembly`; PHG's samtools in `ZEAL/envs/phgv2-conda` |
| Trimmomatic, FastQC | 0.39, 0.12.1; batch-1 trimming parameters (PLAN §3 row 1b) | `ZEAL/envs/zealgt_reads` (new, `envs/zealgt_reads.yml`, xfer job 968339) |
| duplicate marking | `samtools markdup -d 2500` (decided, PLAN §4 #1) | `.../conda/env/assembly` |
| Picard CollectWgsMetrics, MultiQC | picard 3.5.0, multiqc 1.25 | `.../conda/env/qc` |
| bcftools / htslib | mpileup `-I -q20 -Q20 -a AD` | `.../conda/env/nilhmm` |
| CRISP | built from source | `ZEAL/envs/crisp/bin/CRISP.binary` |
| Python 3 | standard library only (step 4, union, gap filling) | `.../conda/env/assembly` or `env/qc` (env/nilhmm has no `python3` in its bin, checked 2026-09-27) |
| R 4.x | data.table, ggplot2, logger, nilHMM 0.3.0 (RTIGER caller) | `.../conda/env/nilhmm` |
| PHG | 2.5.14 + JDK 21 (+ agc, tiledb) | `ZEAL/envs/phgv2`, `ZEAL/envs/jdk21`, `ZEAL/envs/phgv2-conda`, `ZEAL/envs/phgv2-tiledb` |
| Nextflow | 26.04.6 | `/share/maize/frodrig4/conda/env/nextflow` |
The `/share/maize/frodrig4/conda/env/*` environments are used as they are (user, 2026-09-27: no rebuild, move or deletion). Only tools
missing from all of them get a new env, built once from a pinned yml in `envs/` into `ZEAL/envs/` (persistent, off the /share file quota).

## 4. Compute (measured per unit)
| stage | unit | cpus | memory | wall time | disk |
|---|---|---|---|---|---|
| read_demultiplexing | BC1 library (12 samples) | 8 | 16 GB *req.* | ~2 h (4E); 53–72 min for a 94–140 GB pool, pools in parallel (935092, 945148) | FASTQs ≈ library size (115–150 GB), transient |
| read_demultiplexing | batch-2 row library | 8 | 16 GB *req.* | 18 lines incl. align in 58 min (908026) | small |
| read_alignment | BC1 sample (5–25×), whole genome | 8 | ≥ 32 GB, ≥ 48 GB at ~20× (sort) | 1–4 h; ~12–13 min per 1× of depth (56 min – 2 h 39 min for 4.9–12.5×, 935092 / 945148) | CRAM 1–5 GB; sort temp off node `/tmp` (16 GB) |
| read_alignment | BC2S3 line (0.4–1.2×) | 8 | 32 GB *req.* | 4–9 min (935093); ~10 min per line as an array (945149). A full donor prep (demux + 5 BC1 + ~40 lines) ≈ 4 h | CRAM ~0.2 GB |
| sample_quality_control | sample × panel | 1–2 | < 4 GB (est.) | minutes (est.) | small |
| variant_discovery | donor × chr10 (witness merge + CRISP + veto + B73 counts + step 4) | 8 | 48 GB *req.*; CRISP 0.35 GB measured | 8–17 min | witness BAM ~2 GB (temp), CRISP VCF ~30 MB |
| marker_union | donor set × chr10 | 1 | < 1 GB | seconds | < 1 MB |
| donor_allele_calling | per sample (counts) / donor set (joint step 4 + gap filling) | 1–2 | < 16 GB | 1–3 min per sample; ~1 min joint | tens of MB |
| ancestry_inference | donor × chr10 (pileup of lines + RTIGER) | 4 | < 16 GB | ~1–2 min | small |
| genotype_imputation | chromosome (PHG database, all founders) | 8 | JVM `-Xmx40g` *req.* | 14 min for 5 founders | DB 0.2–1.2 GB |
| genotype_imputation | donor × chr10 (export, k-mer index, map, paths) | 8 | 40 GB heap *req.* (true need unmeasured) | ~5 min | k-mer index ~0.4 GB (delete after) |
Cluster: Slurm, `--account=maize_cpu --partition=compute_partners --qos=short` (≤ 2 h) for everything that fits; compute/normal for
BC1 alignment of deep libraries; downloads on `--partition=xfer --mem=8G`. Genome-wide ≈ chr10 × 14 for the per-chromosome stages;
demultiplexing and alignment are already genome-wide.

## 5. Hard-coded today → parameters in zealgt
| value | where hard-coded now |
|---|---|
| project root `/rsstu/users/r/rrellan/BZea/ZEAL` | 44 tracked files (`Z=` in every sbatch; `params.zeal` in `nextflow.config`) |
| results subdirectories (`results/pilot_*`, `results/qcset_designB`, …) | every sbatch (`OUT=`, `U=`, `P=`) |
| `workDir = ${params.outdir}/work` (on /rsstu) | `nilhmm/nextflow.config` — the cause of 3.2 TB in `work/` (audit) |
| conda prefixes `/share/maize/frodrig4/conda/env/{assembly,nilhmm,nextflow,qc}` | sbatch headers, `nextflow.config` |
| tool paths `ZEAL/envs/crisp/…`, `ZEAL/envs/phgv2/…`, `ZEAL/envs/jdk21` | discovery and PHG scripts |
| reference `ZEAL/reference/B73.fa`, chr10 FASTA | ~20 scripts |
| lowcopy BED `pilot_1B_chr10/union/union_chr10.bed` | discovery, union, PHG |
| B73 control CRAMs and their map rows (`B73_ERR3288215` 15.5×, `B73_skim10` 5.7×) | `donor_discovery_chr10.sbatch`, `count_once_step4.sbatch` |
| demux QC source (`results/gate2/demux_qc/…`, snapshots in `pilot_mix_chr10/`) | discovery submit scripts |
| chromosome `chr10`, length 152,435,371 | most PHG / painting scripts |
| thresholds: MAPQ 20, BQ 20, `-p 12`, `--minc 2`, tier LLRs 6.9 / 4.6 / 2.2 / −4, n ≥ 12, gap ALT ≥ 0.999, prior weight w = 2, RTIGER rigidity 500, PHG F = 0 / stay 0.99999 | scripts and `pilot_step4_postfilter_llr.py` |
| Slurm account / partition / QOS, cpus, memory, time | every sbatch header; `nilhmm/modules/*.nf` |
| B73 check label, sample-name conventions (`S_<pool>_<col>`, `P<plot>`, `PN*_SID*`) | discovery, painting |
In zealgt these go to one config (paths, environments, cluster profile) plus the run card (donors, chromosomes); thresholds stay in the
module that owns them, with the defaults above.
