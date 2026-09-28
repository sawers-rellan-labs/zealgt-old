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
| Trimmomatic, FastQC | 0.39, 0.12.1; batch-1 trimming parameters (PLAN §3 row 1b) | not in the zealbc1 envs; zealgt module envs (nf-core trimmomatic / fastqc) |
| duplicate marking | `samtools markdup -d 2500` (decided, PLAN §4 #1) | `.../conda/env/assembly` |
| Picard CollectWgsMetrics, MultiQC | picard 3.5.0, multiqc 1.25 | `.../conda/env/qc` |
| bcftools / htslib | mpileup `-I -q20 -Q20 -a AD` | `.../conda/env/nilhmm` |
| CRISP | built from source | `ZEAL/envs/crisp/bin/CRISP.binary` |
| Python 3 | standard library only (step 4, union, gap filling) | `.../conda/env/assembly` or `env/qc` (env/nilhmm has no `python3` in its bin, checked 2026-09-27) |
| R 4.x | data.table, ggplot2, logger, nilHMM 0.3.0 (RTIGER caller) | `.../conda/env/nilhmm` |
| PHG | 2.5.14 + JDK 21 (+ agc, tiledb) | `ZEAL/envs/phgv2`, `ZEAL/envs/jdk21`, `ZEAL/envs/phgv2-conda`, `ZEAL/envs/phgv2-tiledb` |
| Nextflow | 26.04.6 | `/share/maize/frodrig4/conda/env/nextflow` |
The table above is where the tools ran until now (zealbc1); those `/share/maize/frodrig4/conda/env/*` envs are being deleted by the
user (2026-09-28) and their exact package lists are kept in `envs/legacy_zealbc1/`. zealgt: every module has its own pinned
`environment.yml` (+ `build.sh` for non-conda tools: CRISP @ 1a9027e, nilHMM @ 248e67e), built by `scripts/build_envs.sh` as an xfer job
into `/share/maize/frodrig4/conda/zealgt/` (never `/rsstu`: too slow); `envs/manifest.tsv` lists what was built.
`ZEAL/envs/zealgt_reads` (Trimmomatic + FastQC, xfer job 968339) was built on /rsstu by mistake and removed 2026-09-28.

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

**Measured usage (2026-09-28, from `sacct` and the nilhmm `trace.txt` files; *req.* above = what was asked, this = what was used):**

| task (zealbc1) | source | tasks | cpus alloc → used | peak RSS | wall | I/O per task |
|---|---|---|---|---|---|---|
| DEMUX, BC1 pool (cutadapt) | `ZEAL/results/pipeline_info/trace.txt` (pools 2H, 3B–3E) | 5 | 8 → 3.8–4.7 | 0.61–0.70 GB | 53 min – 1 h 12 | 1.2–1.8 TB read + written |
| DEMUX, batch-2 row | `results/bc2s3_batch2/pipeline_info/trace.txt` | 32 | 8 → 2.1–2.8 | 0.56–0.59 GB | 12–13 min | — |
| ALIGN, deep BC1 sample (minibwa + sort, whole genome) | same trace, samples S_2H_1, S_3B_11, S_3C_9, S_3D_8, S_3E_7 | 5 | 8 → 6.8–7.1 | 14.1–22.1 GB | 1 h 46 – 2 h 01 | 61–110 GB written (CRAM + sort temp) |
| realign, BC2S3 line (0.4–1.2×) | sacct arrays 935093, 945149 | 84 | 8 → 4.9–5.7 (61–71 %) | 9.9–24.3 GB (median 19–21) | 1–9 min | 7–12 GB written |
| markdup-only import, BC1 CRAM | sacct array 963772 | 94 | 4 → 2.4 (59 %) | 1.0–11.4 GB (median 3.9) | ≤ 16 min | ~16 GB written |
| Nextflow head job | sacct 908026, 935092, 945148 | 3 | 1 | **3.8 GB of 4 GB requested** | 58 min – 3 h 55 | — |

Implications: DEMUX needs ~1 GB, not 16 GB, and uses ~4–5 cores of 8; deep ALIGN peaked at 22 GB (24 GB first attempt is right, the
48 / 72 GB retries cover the ~20× samples that OOMed); the head job sits at its 4 GB limit — request 8 GB. Not measured anywhere yet:
Trimmomatic, FastQC, Picard CollectWgsMetrics (never ran in zealbc1), variant_discovery memory beyond CRISP.

**Measured usage, zealgt Gate 1 (2026-09-28, `trace.txt` of `results/zealgt/gate1_1A` and `gate1_import`; head jobs 969703,
969903; `agent/handover_20260928_233000_gate01.md`).** BC1 pool 1A, first 1,000,000 read pairs (949,830 assigned, 15–138 k pairs per
sample, 12 samples), `-profile hazel,short`; full 1A = 1,848,115,736 pairs (nilhmm `results/demux/1A/1A.cutadapt.json`), i.e. × 1848.

| process | tasks | cpus alloc → used | peak RSS | realtime | full-library estimate (× 1848, linear in pairs) |
|---|---|---|---|---|---|
| DEMUX (cutadapt, 1 M pairs) | 1 | 6 → 1.6 | 0.62 GB | 14 s (cutadapt 4.5 µs/pair) | ~2.3 h on 6 cores at that rate (zealbc1: 53–72 min for 94–140 GB pools on 8) |
| DEMUX_QC | 1 | 1 → 0.9 | 64 MB | 10 s | constant (first 100 k reads per sample) |
| TRIMMOMATIC | 12 | 8 → 1.8–3.0 | 0.17–0.44 GB | 2.4–14.7 s (~10 k pairs/s) | **~7 h** for the largest sample (S_1A_6, ~255 M pairs); I/O-bound (2.5–3 of 8 cores) |
| FASTQC | 12 | 2 → 0.8–1.8 | 0.18–0.43 GB | 3.5–7.3 s (~58 k pairs/s after JVM start) | ~1.2–2 h for the largest sample (over the 1 h short cap: FASTQC added to the `normal` profile list) |
| ALIGN_MARKDUP | 12 | 8 → 1.4–3.6 | 4.6–6.6 GB (index load) | 17–25 s | zealbc1 deep samples: 1 h 46 – 2 h 01, 14–22 GB (above) |
| SAMTOOLS_STATS | 12 + 2 | 2 → 1.5–1.7 | 0.38–0.81 GB | 4–8 s; import S_2A_11 (1.16 GB CRAM) 2 min 58 | ~20 min for a ~7 GB CRAM |
| PICARD_COLLECTWGSMETRICS | 12 + 2 | 2 → 1.0 | 2.2–3.8 GB | **6 min 22 – 7 min 36 on near-empty CRAMs** (genome-walk floor); PN5_SID464 (155 MB) 8 min 48; S_2A_11 (1.16 GB) 20 min 33 | ~1–2 h for a ~7 GB CRAM (normal profile, 4 h) |
| PROVENANCE, REGISTRY | 12 + 2, 1 | 1 | < 10 MB | < 1 s | constant |
| MULTIQC | 1 + 1 | 1 → 0.07 | 0.6 GB | ~2 min | ~constant |
| MARKDUP_IMPORT | 2 | 4 → 2.6–2.9 | PN5_SID464 3.2 GB (44 s); S_2A_11 **7.5 GB** (5 min 54) after the fix | — | S_2A_11 was OOM-killed at 12 GB with sort = (mem − 2 GB) (job 969706); sort now gets half of the memory |
| head job | 7 | 1 | 0.35–0.60 GB (sacct MaxRSS) | 3–33 min | — |

Disk / files (Gate 1 1A): `work/` 427 MB, **881 files** for 76 tasks (file count does not grow with depth); TMPDIR empty after the run
(the OOM-killed import task left 2.8 GB / 34 files in `gate1_import/tmp`). Largest parts: demux FASTQs 128 MB, Trimmomatic
`-trimlog` 153 MB (**uncompressed, ~160 B per pair, larger than the trimmed FASTQs**), trimmed FASTQs ~110 MB. Full 1A, × 1848: demux
FASTQs ≈ 237 GB, trimmed ≈ 200 GB, trimlogs ≈ 282 GB → **`work/` peak ≈ 0.8 TB** (plus sort temps in TMPDIR), above the 2 × library
(≈ 0.5 TB) assumed in PLAN §5 rule 3; dropping `-trimlog` would bring it to ≈ 0.45 TB. CRAMs ≈ 0.30 × raw (1A: 41 MB for 1 M pairs →
≈ 75 GB for the library). Store per sample: CRAM + crai + markdup stats + stats + CollectWgsMetrics + provenance (+ 2 versions.yml) = 8 files.

**Notes from Gate 2 (BC1 3A, full library, `-profile hazel,normal`, 2026-09-28; they supersede the estimates above where they differ).**
- **ALIGN_MARKDUP memory.** All 12 first attempts were OOM-killed at 24 GB, and retries at 48 / 72 GB too, with the old sort budget
  `-m` = (mem − 12 GiB) / 4 threads: the budget grows with the attempt, and sort fills it. Sampled RSS (main checkout
  `agent/20260929_032000_align_rss.tsv`): minibwa ≈ 9–10.5 GB, flat; `samtools sort` grows to its full `-m` × threads budget + 5–10 %
  for samples above ~20 M pairs, so a 12 GiB reserve was too little. New rule (main 0a61f9c, branch `simplify` Phase A): first attempt
  24 GB × attempt (`params.align_memory_gb`), sort threads = min(4, cpus), sort `-m` = max(768 MB, (task.memory − 16 GiB) × 0.75 /
  threads) (`align_mem_reserve_gb` 16, `align_sort_mem_share` 0.75) → 1.5 GB × 4 at 24 GB, 6 GB × 4 at 48 GB. Not yet rerun at scale.
  The zealbc1 ALIGN row above (14–22 GB peak) had another sort setting and does not carry over.
- **MARKDUP_IMPORT memory:** the same bounded share with its own reserve, sort `-m` = (task.memory − 2 GiB) × 0.75 / threads
  (`import_mem_reserve_gb` 2; was half of the memory) → 7.5 GB of sort at the 12 GB first attempt.
- **TRIMMOMATIC:** 25–31 k pairs/s on full samples (Gate 1's ~10 k pairs/s was start-up on tiny inputs), so the largest sample fits in
  4 h × attempt; the 12 h `normal` override never applied (it lost to a combined selector, PLAN §6) and is removed. The "~7 h" estimate
  in the Gate 1 table is superseded. `-trimlog` is no longer written (functional TRIMMOMATIC patch), which removes the trimlog share
  of the `work/` peak.
- Resources are set only by directives (`conf/hazel.config`, `conf/normal.config`, `conf/short.config`) and read in the scripts as
  `task.cpus` / `task.memory` (nf-core standard, PLAN §2); `scripts/check_resources.sh` checks what each process actually gets.
- The FASTQ checkpoint (PLAN §3, §5 rule 3) adds ≈ 1 × raw per library on `/share` (at most `--max_libraries` libraries: requested + already checkpointed), hardlinked from `work/`, so no space or
  inode beyond `work/` while the task dirs exist.

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
