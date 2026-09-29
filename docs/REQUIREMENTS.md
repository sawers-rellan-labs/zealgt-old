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
| cutadapt (trimming), FastQC | 5.2 (`-a`/`-A` TruSeq, `--nextseq-trim=15 -m 36 --compression-level 4`; PLAN §3 row 1b), 0.12.1 | zealgt module envs (nf-core cutadapt / fastqc); Trimmomatic 0.39 (batch-1 parameters) until 2026-09-29, replaced (comparison in §4) |
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

**Measured usage, zealgt Gate 2 (2026-09-28, full BC1 library 3A, never demuxed before; `-profile hazel,normal`; traces
`results/zealgt/gate2_3A/pipeline_info/execution_trace_2026-09-28_{07-24-13,10-24-23}.txt`; head jobs 972212 (stopped) and 973369
(`-resume`, COMPLETED 4 h 15, 0.42 GB); `agent/handover_20260929_063000_gate2.md`, calibration `agent/20260928_204500_align_memory_calibration.md`).**
3A: 130.9 GB raw, 3 lanes, 963,478,689 pairs, 916,445,030 assigned (0.951), 18.8–113.8 M pairs per sample.

| process | tasks | cpus alloc → used | peak RSS (trace) | realtime | note |
|---|---|---|---|---|---|
| DEMUX (per lane, since b993c33) | 3 | 6 → 5.4–5.8 | 0.9 GB | 16–17 min per lane (~320 M pairs; ~5 µs/pair on 6 cores) | the lanes run side by side (maxForks 3) |
| MERGE_LANES (cat of lane gzips) | 1 | 4 → 2.7 | < 10 MB | 3 min 51 | 124.7 GB written (a second copy of the demux FASTQs) |
| DEMUX_QC | 1 | 1 → 0.8 | 0.1 GB | 20 s | |
| TRIMMOMATIC | 12 | 8 → 2.9–3.7 | 0.6–0.8 GB | 10 min – 1 h 15 (**25–31 k pairs/s**) | the Gate 1 estimate (10 k/s) was 3× pessimistic; 4 h limit is ample (replaced by CUTADAPT since, below) |
| CUTADAPT (trimming, since 2026-09-29) | — | not yet run at full size in a CRAM gate | — | — | from the comparison below: 6.3 s per M pairs at 4 cores with level-4 output, ≤ 0.12 GB; full size: CRAM Gate 2 wave 1, below (0.40–0.46 GB, ≤ 11 min 39) |
| FASTQC | 12 | 2 → 1.9 | 0.7–0.8 GB | 3–17 min | |
| ALIGN_MARKDUP (completed attempts) | 12 | 8 → 7.0–7.5 | 23.1 (24 GB) / 23.9–46.5 (48 GB) / 48.2 (72 GB) GB | 21 min – 2 h 57 (~0.6 M pairs/min) | see the memory model below |
| SAMTOOLS_STATS | 12 | 2 → 1.2–1.7 | 0.4 GB | 2–11 min | |
| PICARD_COLLECTWGSMETRICS | 12 | 2 → 1.0 | 2.3–3.1 GB | 15–47 min | single-threaded |
| PROVENANCE, REGISTRY, MULTIQC | 12, 1, 1 | 1 | < 0.6 GB | < 2 min | |

**ALIGN_MARKDUP memory model (Gate 2 calibration over all 46 attempts; main checkout `agent/20260928_204500_align_memory_calibration.md`).**
- **Kill threshold:** hazel kills a job at **95 % of its `--mem`** (`AllowedRAMSpace = 95 %`, swap 0); every OOM has sacct MaxRSS = 0.95 × ReqMem.
- **Peak ≈ M + 1.0 × the sort budget** (`-m` × sort threads). M (minibwa after the B73 index load, plus fixmate / markdup, a few MB) ≈ 10 GiB
  while the sample fits the sort buffer unspilled (≈ 0.785 GiB of in-memory sort data per M pairs), **17–22.5 GiB once sort spills** (every
  full BC1 sample at practical allocations): minibwa buffers mapped batches under back-pressure and grows from ~10 to 12–16 GB over a deep
  sample (per-process RSS via `srun --overlap ps`, main checkout `agent/20260929_032000_align_rss.tsv`). Depth explains ~5 % of M (80–112 M
  pairs). Design M = **26 GiB**; ceiling ~35 GiB at 4E's ~311 M pairs.
- **History (3A):** sort = (A − 12 GiB) / 4 → all 12 first attempts at 24 GB and 8 of 10 second attempts at 48 GB OOM-killed (the budget grows
  with the attempt and sort fills it). sort = max(768, (A − 16 GiB) · 3/4 / 4) MiB (main 0a61f9c) → 7 of 8 first attempts at 24 GB (1.5 GiB × 4
  sort) still died (minibwa killed first, pipe `137 1 0 0`); all 7 retries at 48 GB completed (peaks 41.5–46.5 GB, M 17.5–22.5 GiB); S_3A_9
  completed at 24 GB at the cap. **Cost:** 37 non-completed task jobs = 145.7 of the run's 396.6 allocated CPU-h (37 %).
- **Rule (branch `simplify`, applied):** first attempt **48 GB** × attempt (`params.align_memory_gb`); sort threads = min(4, cpus); sort `-m` =
  max(768 MB, (task.memory − **28 GiB**) × 0.75 / threads) (`align_mem_reserve_gb` 28, `align_sort_mem_share` 0.75). At 48 GB: 3840 MB × 4
  = 15 GiB of sort, predicted peak ≈ 26 + 15 = 41 of the 45.6 GiB cap (90 %); retries 96 GB, then 120 GB (resourceLimits). A reserve of 16 GiB
  is at the cap for deep samples at 48 GB, and a 32 GB first attempt is not viable for BC1. The zealbc1 ALIGN row above (14–22 GB peak) had
  another sort setting and does not carry over.

Disk / files (Gate 2): `work/` **332 GB, 1,310 files** at the end (peak ≈ the end state: lane FASTQs 124.7 GB + merged copies 124.7 GB + trimmed
99.4 GB; no trimlog since 98f8bae), plus `tmp/` 0.5 GB / 3 files (sort temps of stopped attempts). Store: 12 × 8 files, CRAMs 0.74–5.32 GB,
**36 GB for 3A = 0.27 × raw**; demux_qc 6 files, registry 2 files. Group quota after the run: 785 GB / 20 TB, 802,230 / 1,000,000 files
(lab-wide; this run holds ~1.3 K). Full-scale planning: `work/` ≈ 3 × raw per library in flight, including the CRAMs (MERGE_LANES doubles the demux FASTQs until
the lane task dirs are cleaned).

**Notes from Gate 2 (BC1 3A, full library, `-profile hazel,normal`, 2026-09-28; they supersede the estimates above where they differ).**
- **ALIGN_MARKDUP memory:** the model and rule above.
  **Time:** 21 min (18.8 M pairs) to 2 h 57 (S_3A_8, 112 M pairs) at 48 GB, linear in the trimmed input (0.215 h per GiB,
  ~0.0995 GiB per M pairs; the attempts at 24 and 72 GB ran 14–19 % under the 48 GB fit, so memory barely moves it). Request (branch
  `simplify`): 0.25 + 0.323 h per GiB × attempt → 3 h 28 for 100 M pairs, 10 h 13 for ~310 M (retry 20 h 26, under the 24 h limit).
- **MARKDUP_IMPORT memory:** the same bounded share with its own reserve, sort `-m` = (task.memory − 2 GiB) × 0.75 / threads
  (`import_mem_reserve_gb` 2; was half of the memory) → 7.5 GB of sort at the 12 GB first attempt.
- **TRIMMOMATIC:** 25–31 k pairs/s on full samples (Gate 1's ~10 k pairs/s was start-up on tiny inputs): 10 min – 1 h 15, linear in
  the raw pair (0.079 h per GiB, ~0.127 GiB per M pairs). Request (branch `simplify`): 0.1 + 0.105 h per GiB × attempt → 1 h 26 for
  100 M pairs, 4 h 14 for ~310 M; the 12 h `normal` override never applied (it lost to a combined selector, PLAN §6) and is removed. The "~7 h" estimate
  in the Gate 1 table is superseded. `-trimlog` is no longer written (functional TRIMMOMATIC patch), which removes the trimlog share
  of the `work/` peak. (History: TRIMMOMATIC was replaced by CUTADAPT on 2026-09-29, next bullet.)
- **CUTADAPT** (replaces TRIMMOMATIC; comparison below): 4.1–5.8 s per M pairs at 4 cores (mean 4.8), 1.9–2.9 at 8, linear in
  the pairs; peak RSS 86–104 MB (gzip level 1). At the chosen level 4 (compression retest below): 6.1–6.4 s per M pairs at 4
  cores (≈ 50 s per GiB). Request (branch `simplify`): 4 cpus, 1 GB × attempt, 0.1 + 0.025 h per GiB of the merged input pair
  (~0.125 GiB per M pairs; × 1.25 margin and × 1.4 node spread), floor 15 min, × attempt → 25 min for 100 M pairs, 1 h 05 for
  ~310 M (short QOS on `normal`); CRAM Gate 2 confirms at full size.
- **Right-sized requests (branch `simplify`, from these 12 samples; main checkout `agent/20260928_145500_gate3_projection.md` §1b,
  cross-check fit in `agent/handover_20260928_233000_rightsize_time.md`):** the right size plus a margin, never a maximum for every
  task (long or large requests wait longer; backfill favours small jobs). Per-sample times = a + b × GiB of the task's own input
  (a closure on the input paths; directives are not hashed), ≥ 1.25 × every Gate 2 time, floor 15 min, × attempt: TRIMMOMATIC
  6 cpus / 2 GB, FASTQC 3 GB, SAMTOOLS_STATS 1 GB, PICARD_COLLECTWGSMETRICS 1 cpu / 5 GB, DEMUX 1 h, MERGE_LANES / MULTIQC 30 min,
  bookkeeping tasks 10 min / 1 GB. On `normal` each task goes to short QOS when it asks ≤ 1 h 45, else to compute / normal.
- Resources are set only by directives (`conf/hazel.config`, `conf/normal.config`, `conf/short.config`) and read in the scripts as
  `task.cpus` / `task.memory` (nf-core standard, PLAN §2); `scripts/check_resources.sh` checks what each process actually gets.
- The FASTQ checkpoint (PLAN §3, §5 rule 3) adds ≈ 0.83 × raw per library (cutadapt L4) on `/share` (at most `--max_libraries` libraries: requested + already checkpointed), hardlinked from `work/`, so no space or
  inode beyond `work/` while the task dirs exist.

**Trimmomatic vs cutadapt (2026-09-29; hazel jobs 988773–988842; measurement log `agent/20260929_182000_trim_comparison_summary.txt`).** 8 M random pairs (fixed seed) from
each of 5 BC1 1A samples of increasing depth (S_1A_12 18.8 M, S_1A_10 40.6 M, S_1A_1 106.6 M, S_1A_3 124.6 M, S_1A_6 166.5 M
pairs), taken from simplify_mem2's merged FASTQs; the same subsample went to every method. Trimmomatic 0.39 with batch 1's
parameters + TruSeq3-PE-2.fa, 8 threads; cutadapt 5.2 variants at 8 cores. Each output: first 2 M pairs → minibwa -x sr → B73 →
samtools stats. Means over the 5 samples:

| metric | raw | Trimmomatic | cutadapt nt15 (chosen) |
|---|---|---|---|
| pairs kept | 100 % | 97.87 % | 99.81 % |
| bases kept | 100 % | 93.10 % | 94.83 % |
| reads still holding the adapter 13-mer `AGATCGGAAGAGC` | 14.7 % | 1.25 % | 0.056 % |
| reads ending in a 5–12-base adapter prefix | 2.7 % | 2.66 % | 0.003 % |
| reads ending in ≥ 10 G, R1 / R2 | 1.13 / 0.85 % | 0.004 / 0.005 % | 0 / 0 % |
| mapped | 99.658 % | 99.661 % | 99.648 % |
| properly paired | 97.32 % | 97.53 % | 97.52 % |
| primary MAPQ ≥ 20 | 62.43 % | 62.49 % | 62.46 % |
| mismatch rate | 0.00580 | 0.00546 | 0.00581 (cutadapt keeps more 3′ bases; SLIDINGWINDOW:4:15 cuts more) |
| aligned bases per read | 132.8 | 132.5 | 132.5 |

Runtime, memory and output size: see the compression retest below (it replaces the first comparison's runtime and size
lines, which were measured at cutadapt's default gzip level 1).

- nt15 = `--nextseq-trim=15 -m 36` with `-a` / `-A` the full TruSeq read-through adapters (production adds `--compression-level 4`, below).
- Variants: `-q 3,15` (no G handling) keeps 0.2 pp more bases but leaves poly-G tails (0.009 / 0.023 %); nt15 + `-q 3,0` is
  byte-identical in its metrics to nt15 (the binned NovaSeq X qualities never fall below Q3 at the 5′ end, so LEADING:3 has no
  effect to replace; cutadapt accepts `--nextseq-trim` together with `-q`); `-Z` changes nothing.

**Compression retest (2026-09-29; hazel jobs of `zg_trimgz`; log `agent/20260929_195500_compression_retest_raw.tsv`).** The same 8 M-pair subsamples of the 5 1A samples,
4 cpus each; means per method (output = both reads, per 8 M input pairs):

| method | s per M pairs (wall) | CPU s per M pairs (user + sys) | output |
|---|---|---|---|
| Trimmomatic, gzip output (its Java Deflater; the size matches zlib level 6: recompressed 453.3 MB vs 453.6 MB at L6) | 38.6 | 105 | 933 MB |
| Trimmomatic, uncompressed | 9.3 | 34 | 5.38 GB |
| cutadapt nt15, level 1 (cutadapt 5.2 default) | 4.3 | 16 | 1089 MB (+17 % vs Trimmomatic) |
| cutadapt nt15, **level 4 (chosen)** | 6.3 | 24 | 997 MB (+6.8 % vs Trimmomatic, for ~2 % more pairs and ~1.9 % more bases kept) |
| cutadapt nt15, uncompressed | 3.7 | 14 | 5.48 GB |

- Compression is ~76 % of Trimmomatic's wall time; trimming alone, cutadapt is ~2.5× faster (3.7 vs 9.3 s per M pairs); end to
  end, level 4 vs Trimmomatic is ~6× faster. Level 4 costs +2 s per M pairs over level 1 and recovers ~60 % of the size increase.
- Peak RSS: cutadapt 0.07–0.12 GB, Trimmomatic 0.41 GB.

**CRAM Gate 2 wave 1 (2026-09-29; partial: Gate 2 paused, PLAN §6).** Run `cram_gate2_w01` (head 992883, code 1760b4f,
`-profile hazel,normal`), trace `ZEAL/results/zealgt/cram_gate2_w01/pipeline_info/execution_trace_2026-09-29_17-10-57.txt` read at
19:40 (summary `agent/20260929_223000_summarise_w01_trace.sh` → `.out`); BC1 2A, 2F, 3B (36 samples) and batch-1 BZea5. Every
completed row below is attempt 1. Memory: Nextflow's "GB" = GiB; hazel kills at 0.95 × the request.

| process | tasks done | cpus alloc → used | request → peak RSS | realtime | note |
|---|---|---|---|---|---|
| DEMUX, BC1 lane | 10 of 10 | 6 → 5.1–5.8 | 2 GB → 0.91–0.99 GB | 3B (4 lanes, ~194 M pairs) 9–11.5 min; 2A / 2F (3 lanes, ~300–325 M) 15–17 min | as Gate 2 3A |
| DEMUX, batch-1 lane (BZea5, 96 barcodes → 192 gz outputs, cutadapt `-j 4`) | 0 of 2 | 4 → — | **2 GB: OOM, then hung**; 4 GB: MaxRSS 3.99 GB | — | below |
| MERGE_LANES | 3 | 4 → 2.0–3.4 | 1 GB → 12 MB | 2 min 34 – 5 min 20 | |
| DEMUX_QC | 3 | 1 | 1 GB → 69 MB | 15 s | |
| CUTADAPT (L4) | 36 | 4 → 3.8–3.9 | 1 GB → **0.40–0.46 GB** | 3 min 59 – 11 min 39 (S_2A_2, ~106 M pairs: ~6.6 s per M pairs) | all under the 15 min floor; peak 4× the retest's 0.07–0.12 GB (still < half the request) |
| FASTQC | 36 | 2 → 1.6–2.0 | 3 GB → 0.74–0.97 GB | 5 min 49 – 15 min 52 | |
| ALIGN_MARKDUP | 22 of 36 | 8 → 7.1–7.4 | **48 GB → 32.4–36.2 GB** (71–79 % of the 45.6 GiB cap) | 36 min 50 – 1 h 55 (S_3B_8, rchar 205 GB) | below |
| SAMTOOLS_STATS | 19 | 2 → 1.1–1.7 | 1 GB → 0.39–0.43 GB | 4 – 7 min | |
| PICARD_COLLECTWGSMETRICS | 16 | 1 → 0.98 | 5 GB → 3.8–4.1 GB (the 4 GB `-Xmx`) | 20 min 51 – 31 min 51 | heap-bound, not data-bound |
| PROVENANCE | 21 | 1 | 1 GB → < 12 MB | < 1.3 s | |

- **ALIGN_MARKDUP at 48 GB:** peak 32.4–36.2 GB for inputs of rchar 96–205 GB (~2× range), so the peak barely depends on depth;
  with 15 GiB of sort that is M ≈ 17–21 GiB, inside the spilled-sort range above and below the design M = 26 GiB (predicted peak 41
  GiB: the rule has ~5 GiB more margin than assumed). Expected to hold for 2B / 2H (131–140 M pairs); not yet measured there.
  %cpu 706–745 of 800. One slow outlier: S_3B_7 1 h 01 for rchar 110 GB (node spread).
- **Batch-1 DEMUX (BZea5) failed at full size.** Attempt 1 (2 GB; jobs 992922, 992924): OOM-killed ~80 s after cutadapt started
  (sacct `OUT_OF_MEMORY`, MaxRSS 1.99 GB = 95 %), then the task **hung** with no CPU and no `.exitcode` until its 2 h limit (exit
  140, 1 h 59; the task dir held 277 KB). Attempt 2 (4 GB, 4 h; jobs 993890, 993891): MaxRSS 3.99 GB (95 %, `sstat`) after ~4 min
  of cutadapt (AveCPU 16.6 min), ~1.2 GB of demux output per lane, then hung again (0 CPU). Memory grows with the data processed.
  Gate 1 (`simplify_b1g1`, 4 M pairs per lane, `agent/20260929_164924_trace_b1g1.txt`) had peaked at **1.6 GB of 2 GB** in 52–56 s
  (~13 µs per pair at 4 cpus) → **~50 min per ~228 M-pair lane** expected once fixed. Fix in progress (`conf/hazel.config` DEMUX
  TODO); re-measure at full size.
- **Checkpoint, measured** (`du -s`, 19:40): 2A 107.3 GB, 2F 97.4 GB, 3B 85.8 GB = **0.81 / 0.80 / 0.81 × raw** (290.5 GB for
  360 GB raw), 3 % under the 0.83 × raw estimate (299.9 GB).

**CRAM Gate 2, B73 controls (`cram_gate2_b73`, head 992885, COMPLETED 1 h 26 wall, 17:10–18:36; trace
`ZEAL/results/zealgt/cram_gate2_b73/pipeline_info/execution_trace_2026-09-29_17-10-57.txt`).**

| process | sample | cpus alloc → used | request → peak RSS | realtime | I/O |
|---|---|---|---|---|---|
| MARKDUP_IMPORT | B73_skim10 (7.3 GB BAM) | 4 → 2.8 | 12 GB → 9.4 GB | 9 min 51 | rchar 160 GB |
| MARKDUP_IMPORT | B73_ERR3288215 (8.9 GB CRAM) | 4 → 2.9 | 12 GB → **10.6 GB (93 % of the 11.4 GiB cap)** | 25 min 03 | rchar 377 GB |
| SAMTOOLS_STATS | both | 2 → 1.6–1.7 | 1 GB → 0.39–0.40 GB | 4 min 38; 11 min 08 | |
| PICARD_COLLECTWGSMETRICS | both | 1 → 0.98 | 5 GB → 3.8–3.9 GB | 25 min 39; **54 min 26** (ERR3288215; the ~2.5 h estimate was 3× high) | |
| MULTIQC, PROVENANCE | | 1 | < 0.6 GB | < 2 min | |

MARKDUP_IMPORT at 15.5× sits 7 % under the kill line at the 12 GB first attempt (7.5 GiB of sort + ~3 GiB): a deeper import
would OOM and retry at 24 GB.

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
