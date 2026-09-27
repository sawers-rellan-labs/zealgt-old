# Plan (DRAFT) — pipeline v2: one Nextflow pipeline from raw libraries to ancestry and imputed genotypes

Status: **proposal, 2026-09-24**, for discussion; nothing implemented. Storage section (§5) filled from the disk audit
(`nilhmm/bin/audit_du.sbatch`, job 946049, results in `ZEAL/results/audit_du_20260924/`).

## 0. First work in zealgt (user, 2026-09-24): no more demultiplexing of the libraries already in use
Demultiplexing is the most expensive step to repeat. In the nilhmm runs, pool 1B was demuxed ~9 times during the 09-11 → 09-14 gate runs,
and every other library was demuxed once but only its donor's samples were aligned, leaving ~2.8 TB of FASTQs for unaligned samples in
`work/` (§5). Nextflow did not prevent this: `workDir = ${params.outdir}/work` gave every new outdir an empty cache, demux FASTQs were not
published, and hash changes between tries reran DEMUX. These two tasks come before any other zealgt work.

### Development starting data (ready, 2026-09-24)
Two mexicana donors with 5 BC1 samples each (the QC-set design: 5 pools per founder), fully demultiplexed and aligned, all files and
indexes checked on hazel:

| donor | BC1 samples (`results/cram/`) | BC1 total λ | BC2S3 lines (0.4×, realigned) | demux QC rows | discovery |
|---|---|---|---|---|---|
| Zx.0540_P3 | S_2A_3, S_2A_11, S_2B_8, S_2F_1, S_2F_12 | 43.2× | 40, `results/bench_zx0540_chr10/bc2s3_realign/cram/` | `results/bench_zx0540_chr10/` | chr10 done with the CRISP fix (job 949447, tier A 40,941; pre-fix 944798 in `discovery/Zx.0540_P3_preBEDfix/`) |
| Zx.0570_P2 | S_2H_1, S_3B_11, S_3C_9, S_3D_8, S_3E_7 | 43.7× | 44, `results/bench_zx0570_chr10/bc2s3_realign/cram/` | `results/bench_zx0570_chr10/` | chr10 done with the CRISP fix (job 949448, tier A 54,395) |

Plus the B73 controls (`results/b73_control/`: ERR3288215 15.5×, skim10 5.7×). These 10 BC1 CRAMs and 84 line CRAMs were made by
nilhmm / `bc2s3_realign.sbatch` (minibwa -x sr, MAPQ 20, `-F 0x904`) **without duplicate marking and without read groups**, so they are
the first imports: MARK_DUPLICATES + read-group pass (Task 2), then zealgt's own variant discovery. The existing Zx.0540_P3 discovery
table predates duplicate marking and serves as the before/after comparison, not as zealgt input. Compare against the rerun
with the CRISP BED-end fix (§4 #9), not the pre-fix table (`discovery/<donor>_preBEDfix/`), so the comparison measures duplicate marking only.

### Task 1 — turn the existing demux FASTQs into CRAMs, once
Align every not-yet-aligned sample of the libraries that are already demuxed, from the FASTQs still in the nilhmm `work/` directories
(by `-resume` in the original launch directories, so the cached DEMUX tasks are reused, or by an alignment job reading those FASTQs
directly), with duplicate marking; write the CRAMs to the store.

| libraries demuxed | samples | aligned (2026-09-24) | to align | FASTQs now in |
|---|---|---|---|---|
| BC1 1B | 12 | 12 (`results/align_membench`) | 0 | `results/gate2/work` |
| BC1 4E, 4F, 4G | 36 | 4 (Zv.0490_P4) | 32 | `results/work` (launch `results/pool_run_4E4F4G`) |
| BC1 1A | 12 | 1 (S_1A_4) | 11 | `results/work` (launch `results/pool_run_1A`) |
| BC1 2A, 2B, 2F | 36 | 5 (Zx.0540_P3; CRAMs checked 09-24) | 31 | `results/work` (launch `results/pool_run_2A2B2F`) |
| BC1 2H, 3B–3E | 60 | 5 (Zx.0570_P2; CRAMs checked 09-24) | 55 | `results/work` (launch `results/pool_run_2H3B3C3D3E`; other session's run — its decision) |
| BC2S3 batch-2 rows V22A–H, V23A–H, V24A–B | 216 wells | ~30 lines + checks | ~185 | `results/bc2s3_batch2/work` |
Scale: ~130 BC1 samples (~1 h × 8 cpu each, ~1,000 CPU-h) and ~185 lines (minutes each). **Until this is done and verified, those `work/`
directories are the only copy of the demuxed reads and must not be cleaned.** Done = every sample of these libraries has a verified,
non-empty CRAM in the store; then the FASTQs can go (§5, cleanup group A–C).

### Task 2 — make repeated demultiplexing impossible by construction
- **Development starts from CRAMs.** Development entries take a sample sheet of existing CRAMs; `read_demultiplexing` is not part of them.
- **Demux registry in the store.** A library is registered as done when its demux QC table and all its sample CRAMs are in the store.
  `read_demultiplexing` refuses a registered library unless it is named explicitly with `--force-demux <library>`.
- **One pass per library** for any library demuxed from now on: one task demuxes the library, aligns **all** its samples, marks
  duplicates and writes the CRAMs; FASTQs live only in that task's scratch and are deleted when it ends. `--samples` never restricts which
  samples of a demuxed library get aligned.
- **Reuse of existing outputs:** entries read existing CRAMs / tables through sample sheets; the workflow computes only what is missing
  in the store; CRAMs imported from nilhmm (made without duplicate marking) get a MARK_DUPLICATES-only step, not a realignment.
- **Raw libraries are read-only inputs.**

## 1. Why
The chr10 pilots ran as standalone sbatch scripts next to the `nilhmm/` pipeline. The same step was implemented more than once and the
copies drifted: B73 pools inside vs outside CRISP, `mpileup -I` present in one pileup and missing in another, a demux QC table overwritten
by every pool run, no duplicate removal anywhere. Each fix had to be applied in several places. One module per step removes that class
of error. The known issues this plan must settle are in §4.

## 2. Principles

### The rerun problem these principles address
In the nilhmm runs, a costly step (demultiplexing, whole-genome alignment) that had already completed ran again after an edit that could
not change its output: a comment, a cosmetic change to a module, or a resource reallocation. Each rerun left a new set of task
directories, so `work/` multiplied for menial reasons (the audit found ~3.2 TB there, §5).

The cause is how `-resume` decides: it reuses a task only if the task's **hash** is unchanged, and the hash covers the process's script
text after variable substitution, its inputs, and its environment (conda / container).

| change | reruns the task? | why |
|---|---|---|
| comment **inside** the `script:` block (bash `#`) | **yes** | it is part of the script text |
| comment **outside** it (Groovy `//` above the block) | no | not part of the script |
| `cpus` / `memory` / `time` changed, script uses `${task.cpus}` / `${task.memory}` (e.g. `-@ ${task.cpus}`, `-Xmx`) | **yes** | the value is substituted into the script text |
| the same resource change, script does not reference it | no | directives alone are not hashed |
| an input file touched (new mtime), same content | **yes** by default | default cache mode includes mtime |
| the same, with `cache 'lenient'` | no | path + size only |
| any edit, when the task's output already sits in its `storeDir` | no | the task is skipped whatever changed |

### Principles
1. **One module per step**, used by every entry; no standalone copies of a module's command.
2. **Separate entries per stage** (the existing `--entry` dispatcher): editing a downstream module never puts upstream tasks at risk.
3. **Costly, reusable outputs live in a permanent store (`storeDir`), not in `work/`**: CRAMs, per-pool demux QC. A task whose stored
   output exists is skipped whatever changed in the module; rerunning it is a deliberate act (delete the stored output).
4. **Hash hygiene** (from the table above):
   - comments and notes outside the `script:` block (Groovy `//`), never as bash `#` inside it;
   - threads and memory read from Slurm at run time (`-@ \$SLURM_CPUS_PER_TASK`), not `${task.cpus}` / `${task.memory}` in the script,
     so reallocating resources does not change the task hash;
   - `cache 'lenient'` (path + size, not mtime) on processes with large inputs.
5. **Temporaries die inside the task** (merged witness pool, sort temp, demux FASTQs if merged with ALIGN; see §5).
6. Tools: minibwa, samtools, bcftools, CRISP, nilHMM, PHG — the ones in use; environments prebuilt and referenced by prefix.

## 3. Two workflows, stages and modules
The pipeline is two workflows in this repository, with the **store as the only contract** between them (decided 2026-09-24):

| | **Workflow 1 — read processing** | **Workflow 2 — genotyping** |
|---|---|---|
| input | raw libraries + sample maps | the CRAM store + a sample sheet + a run card |
| runs | once per library, then done (demux registry) | many times: development, new donors, parameter changes |
| output | analysis-ready CRAMs + read/alignment QC + provenance + registry | discovery tables, markers, ancestry, imputed genotypes |
| cost | heavy (hours per BC1 library; ~3,000 CPU-h for all BC1 samples) | light per donor (minutes per chromosome) |
| profile | compute/normal, large scratch | short QOS |
Genotyping development never contains a demultiplexing or alignment step, so no edit to it can trigger one. Genotyping checks each
CRAM's provenance record against the current read-processing settings.

### Workflow 1 stop point: the analysis-ready CRAM
Per sample, into the store: CRAM + index (B73 v5, coordinate-sorted, read groups in every read, **duplicates flagged, not removed**,
all mapped primary reads, **no MAPQ filter**); per-sample QC (FastQC of the trimmed reads, `samtools stats`/`flagstat`, markdup
stats, mosdepth λ); per-library demux QC and MultiQC; a provenance record (source, demux tool, trimming parameters, aligner and
version, markdup settings, code version); the registry entry. MAPQ, base-quality and duplicate filters are applied by workflow 2 at
read time (`mpileup -q20 -Q20`, CRISP `--mmq 20`), so a threshold change never needs realignment. (The nilhmm CRAMs were written with
`-q 20 -F 0x904`; new CRAMs are not.) Anything that needs reference ranges, a site panel or the pedigree belongs to workflow 2.

### One read-processing standard for all three sources
| source | libraries | input adapter | barcode layout | sample map |
|---|---|---|---|---|
| BC1 pools | 32 (1A–4H), `BC1_dna_raw/` | plain FASTQs | inline, symmetric on R1 and R2 (`-g`/`-G`) | `meta/bc1_well_map.csv` |
| BC2S3 batch 2 | 32 rows (V21A–V24H), `BC2S3_batch_2_dna_raw/` | plain FASTQs | inline, symmetric on R1 and R2 | `meta/bc2s3_batch2_well_map.csv` |
| BC2S3 batch 1 (CLY2023) | 17 plate pools in `sara/DNA_Sequencing_raw/BZea/NVS188B_*_R{1,2}.tar` (1.5 TB, read-only) | members streamed out of the tars (`tar -xOf`), lanes concatenated; plate pool = 6-bp Illumina index in the header | **8-bp inline barcode on R1 only** (checked 2026-09-24: top-96 5′ 8-mers cover 91.9% of reads vs 6.6% at base 31) | `BZea_Sample_ID.xlsx` (1,632 wells: barcode, plate, plate index, running number, genotype) → a well map; joins to check: plate index → `BZea<n>` files, running number → `PN<plate>_SID<n>` |
Same steps for every library, in one task per library: cutadapt exact-match demux (`-e 0 --no-indels`; R1-only anchoring for batch 1)
→ Trimmomatic PE with batch 1's original parameters (`ILLUMINACLIP 2:30:10, LEADING:3, TRAILING:3, SLIDINGWINDOW:4:15, MINLEN:36`) →
minibwa -x sr → read groups → `samtools fixmate -m` → `sort` → `markdup -d 2500` → CRAM; FASTQs deleted per sample as it finishes
(peak scratch ≈ 1.1 × the library). Batch 1 is demultiplexed again from the tars so all ~2,400 samples share one provenance; Nirwan's
sabre + Trimmomatic FASTQs (`sara/BZea/filtered_S/`) stay as a fallback and comparison.

| # | workflow | entry | modules | per | main output (store) |
|---|---|---|---|---|---|
| 1 | 1 | `read_demultiplexing` | FETCH_LIBRARY (source adapter) → DEMUX (cutadapt exact inline) → DEMUX_QC | library | per-sample FASTQ (task scratch only), `demux_qc/<library>.tsv` |
| 1b | 1 | `read_trimming` | TRIMMOMATIC (batch-1 parameters) → FASTQC | sample (inside the library task) | trimmed FASTQ (task scratch only), FastQC report |
| 2 | 1 | `read_alignment` | ALIGN (minibwa -x sr) → READ_GROUPS → **MARK_DUPLICATES** (`samtools markdup -d 2500`) → CRAM (no MAPQ filter) → SAMTOOLS_STATS → MOSDEPTH → MULTIQC | sample | `cram/<sample>.cram` + QC + provenance |
| 2b | 2 | `sample_quality_control` | QC_PANEL_COUNTS (`mpileup -I` at a blind QC panel, one task per sample) → COVERAGE_QC → RELATEDNESS_QC → DONOR_CONTENT_QC | sample / cohort | `sample_qc.tsv`: pass/fail + reason per sample; discovery and every caller read it |
| 3 | 2 | `variant_discovery` | WITNESS_POOL → CRISP (BC1 samples + witness only) → BED_CLIP (`bcftools view -T`, §4 #9) → WITNESS_VETO → B73_CONTROL_COUNTS (`mpileup -I`) → POOLED_LIKELIHOOD_TIERS | donor × chr | `step4/<donor>.sites.tsv.gz` |
| 4 | 2 | `marker_union` | MARKER_UNION (tier-A sites of the donor set; multi-allelic dropped) | donor set × chr | `union/<set>_<chr>.tsv.gz` |
| 5 | 2 | `donor_allele_calling` | UNION_SITE_COUNTS (`mpileup -I -T union`, one task per sample) → JOINT_POOLED_LIKELIHOOD → GAP_FILLING (`dhd_bayes`) | sample / donor set × chr | donor allele table |
| 6 | 2 | `ancestry_inference` | LINE_ALLELE_COUNTS → RTIGER (rigidity 500, run as in zealbc1 — §4 #10) | donor × chr | ancestry segments per line |
| 7 | 2 | `genotype_imputation` | DONOR_FOUNDER (gVCF: one reference block per lowcopy range, split at ALT records, no record at missing sites — §4 #11 → pseudo-assembly) → PHG_DATABASE → PHG_IMPUTATION (pairwise: B73 + donor, that donor's lines; F = 0, stay 0.99999) → RASTERIZE | donor × chr | genotypes at the union sites |
| 8 | 2 | `reporting` | CHROMOSOME_PAINTING (PHG no-call shown as no-call, not filled from the flanks), summary tables with the no-call share, KS / single-locus checks | donor × chr | paintings, tables |

### Stage 2b — sample QC before discovery (proposal, 2026-09-24)
Discovery assumes every BC1 sample and every line belongs to its recorded donor; a pollination error, seed mix-up or contaminated
pool breaks that silently (a wrong BC1 sample adds false alleles; a wrong line adds reads to the witness). The check must therefore run
before discovery and must not depend on any donor's discovered sites.
- **Blind QC panel:** lowcopy ranges ∩ teosinte-vs-B73 variants detected by wideseq, defined without any donor assumption. Positions only
  (panel genotypes are imputed). Caveat: distal taxa, huehuetenangensis most, are thin in the panels (1 Zh individual in Schnable 2023).
- **Coverage QC** (as in zealhmm `scripts/zeal_paired_cohort_coverage_qc.R`): covered panel markers per sample × chromosome; a line with
  any chromosome below 2 × rigidity covered markers is excluded from every caller (decided, §4 #13; as in zealhmm); the counts at 10 and 100
  are reported alongside. One table applied to every caller. λ per sample from mosdepth alongside.
- **Relatedness QC:** lines (λ 0.05–1.6) from genotype likelihoods or one random read per site (pseudo-haploid), no hard calls; BC1
  samples from their per-site ALT fractions (correlation of centered frequency vectors). Centered kinship (VanRaden, as in zealhmm
  `zeal_mlm_taxon.R`); a sample is flagged when its kinship to its own donor's samples/lines falls outside the within-donor distribution,
  or when it is closer to another donor. Expected signal: lines are ~87.5% B73, so relatedness comes from teosinte alleles; same-donor
  lines share H_d segments.
- **Donor-content QC:** fraction of panel sites with ALT reads vs the 12.5% expectation — catches B73 contamination (selfing, seed mix),
  which kinship alone does not separate from a line that carries little donor genome.
- Flagged samples are excluded from discovery and from the witness; the table records why.
- Open: the relatedness method for mixed pool/line samples; flag thresholds; whether Zh needs its own panel (e.g. from its assembly).

Donor sets for stages 4–5 are named in a run card (`docs/runs/<run>.md`: purpose, donors with BC1 count / lines / coverage, exclusions),
and each entry checks the run card before starting.

### Teosinte reference variant space from the founder assemblies (plan, 2026-09-24; not yet in the math supplement)
How many sites differ between a teosinte haplotype and B73, per taxon, measured on the reference inbred assemblies rather than on reads.
Uses: the size of the variant space discovery works in, the truth allele set of the QC-set benchmark (PERFECT founder = assembly SNPs ∩
lowcopy BED), and annotation of step-4 tables.

**How it was done (zealbc1 chr10 PHG pilot, 2026-09-17; `agent/PHG_PILOT_chr10.md` step 4, `agent/pilot_1B_chr10_runlog_20260917.md`):**
founder assembly → AnchorWave against B73 v5, chr10 (run directly, not through `phg align-assemblies`) → MAF
(`ZEAL/results/phg_pilot/chr10/maf/`) → PHG `create-maf-vcf` → gVCF of the assembly vs B73 (`phg_pilot/chr10/vcf_files/<founder>.g.vcf.gz`)
→ SNP table `chr, pos, ref, alt` (`ZEAL/results/crisp_bench/<founder>_vs_B73_chr10_snps.tsv`). Only syntenic sequence aligned by
AnchorWave is counted.

| founder (taxon) | SNPs vs B73, chr10 | per chr10 length (~152 Mb) |
|---|---|---|
| TIL18 (mexicana) | 2,031,229 | ~1 / 75 bp |
| Gigi (diploperennis) | 2,090,083 | ~1 / 73 bp |

**In zealgt** (entry `reference_variant_space`, per founder × chromosome):
ANCHORWAVE_ALIGN (assembly vs B73 v5; ~1–2 h × 8 cpu per chromosome, ≤ 16 GB) → MAF_TO_GVCF (PHG `create-maf-vcf`) → ASSEMBLY_SNPS
(a tracked script: biallelic SNPs from the gVCF, `<NON_REF>`/reference blocks excluded, one row per site) → VARIANT_SPACE_SUMMARY
(per founder × chromosome: SNPs, aligned bp, SNPs per aligned kb and per chromosome Mb, SNPs inside the lowcopy BED).
1. **Reproduce first:** the gVCF → SNP-table step of 09-17 is not in any tracked script. ASSEMBLY_SNPS is written from scratch and
   run on the existing chr10 gVCFs; it must return exactly 2,031,229 (TIL18) and 2,090,083 (Gigi) before it is used anywhere else.
2. **Then the other founders:** TIL11 (parviglumis), RIL003 (luxurians; assembly is `.fa.gz`), RIMHU001 (huehuetenangensis) have
   assemblies but no alignment to B73 — one AnchorWave chr10 run each (also needed by the QC set, zealbc1 `docs/PLAN_benchmark_calibration.md`).
3. **Then genome-wide:** the remaining 9 chromosomes for all five founders (~400 CPU-h, the largest item; measure memory on one
   chromosome first).
Outputs go to the store (`ZEAL/store/reference_variants/`), not `work/`. The math supplement gets a text on this only after step 1.

## 4. Known issues and where each is settled
| # | issue (found 2026-09-20 → 24) | settled in | decision needed |
|---|---|---|---|
| 1 | No duplicate removal (BC1, lines, B73 pools). Pooled-caller benchmark and GATK best practices remove/mark PCR duplicates [1, 2]; CRISP paper silent [3] | stage 2 MARK_DUPLICATES | **decided 2026-09-24: `samtools markdup -d 2500`** (optical distance for NovaSeq patterned flow cells), in the alignment stream (`fixmate -m` → `sort` → `markdup`); imported nilhmm CRAMs: collate → fixmate → sort → markdup, same tool. Picard only if library-complexity metrics are wanted |
| 1b | No read groups: CRAMs lack @RG; a header-only RG made GATK count zero reads silently (09-21) | stage 2 | **decided 2026-09-24:** RG in every read, at alignment (`minibwa -R` if supported, else `samtools addreplacerg` inline before `fixmate`); imported CRAMs get it in the MARK_DUPLICATES pass. ID = sample (sample.lane if split), SM = Sample_Id, LB = library (BC1 pool / batch-2 row), PL = ILLUMINA, PU = flowcell.lane. Merged pools (witness) keep one RG. GATK is not used; if ever, the RG is already there. Fields that matter: **SM** (bcftools mpileup sample names) and **one RG per merged pool** (CRISP splits a file by RG). LB is written but no step depends on it: duplicate marking runs per sample CRAM (one library each), merged pools are not deduplicated |
| 2 | CRISP run with `--filterreads 0` (its mismatch filter off; the CRISP paper used ≤ 3 mismatches, MAPQ ≥ 20, base quality ≥ 17 [3]) | stage 3 CRISP | turn it back on? |
| 3 | Insertion records at a SNP position overwrite its counts (ALT → 0) unless `mpileup -I` | one COUNTS helper used by stages 3, 5, 6 | make the helper skip indel records itself |
| 4 | Demux QC table overwritten by every pool run (`results/demux_qc/demux_qc.tsv`; 09-24 the donors' rows had to be saved by hand to `bench_*/demux_qc_*_20260924.tsv`) | stage 1 DEMUX_QC | one file per pool (store) |
| 5 | Witness veto depends on witness depth (10 lines at 0.4x kept 20% of records) | stage 3 VETO | keep "≥ 1 ALT read" or make it depth-aware |
| 6 | Tiers depend on the count source (CRISP vs mpileup disagreed at ~15% of own tier-A sites) | stages 3 vs 5 | which counts define tiers |
| 7 | RTIGER rigidity fixed at 500 vs a density-scaled rule | stage 6 | confirm 500 |
| 8 | Marker union / donor allele calling / gap filling / ancestry inference exist only as standalone scripts (`PHG/bin/`) | stages 4–6 | port as modules |
| 9 | **CRISP reads the `--bed` end one base too far** (found and fixed in zealbc1 2026-09-24, zealbc1 `docs/DECISIONS.md`): it also calls the base right after every range; starts are read correctly (`variantcalls.c` tests `k >= start && k <= end` with raw BED values and a 0-based `k`; reported upstream as vibansal/crisp#34). Evidence: BED `chr10 105269 105270` (base 105,270 only) → CRISP reports 105,271; Zx.0570_P2 raw output has 29 records at range end + 1 (≈ the ~41 expected inside a range) vs 36 at range first bases; 18 of 82,724 rows of the Zx.0540_P3 + Zx.0570_P2 union sit 1 bp past a range end. Size ≤ 1 base per range (8,095 ranges, ~0.03% of the 26 Mb tested); sites inside ranges unaffected | stage 3, right after CRISP | **decided:** `bcftools view -T <lowcopy BED>` on the CRISP VCF before WITNESS_VETO, so step 4, the union and ancestry inference see only in-range sites (zealbc1 `PHG/bin/donor_discovery_chr10.sbatch`, dc95eea). Any zealbc1 table made before dc95eea carries the extra sites (step-4 tables of Zx.0540_P3, Zx.0570_P2, Zv.0490_P4, Zx.0150_P2, Zx.0100_P4, Zd.0040_P1, the QC-set founders, and every union / gap filling / founder / PHG / RTIGER output built on them); zealbc1 `PHG/qcset/variant_discovery.sbatch` is not fixed yet. Rerun with the fix: Zx.0540_P3, Zx.0570_P2 (jobs 949447, 949448; pre-fix outputs in `discovery/<donor>_preBEDfix/`) |
| 10 | nilHMM does not pass a design prior to RTIGER: the "BC2S3" and "BC2S2" RTIGER runs were byte-identical (zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §3.3) | stage 6 | **decided (user, 2026-09-24): run RTIGER as it has been run** (own tier-A sites, rigidity 500, parameters learned from the data); there is no design difference, so no BC2S2-vs-BC2S3 caller comparison |
| 11 | **A records-only union founder is unusable by PHG** (zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §3.2): `gvcf2hvcf` builds a haplotype only from stretches with gVCF records, so a records-only founder became joined 1–2 bp pieces (a 571-bp range → ~15 bp); 5,179 / 8,095 ranges had a founder haplotype and k-mer mapping gave zero TEO calls in all 44 Zx.0570_P2 lines (job 949013) | stage 7 DONOR_FOUNDER | **decided (user, 2026-09-24):** one reference block per lowcopy range, split at ALT records, no record at missing sites → every range has a full-length founder haplotype (B73 + the donor's ALT alleles; a missing site is the only absent base). Consequence: a range with no ALT site is identical to B73 and PHG reports it as no call |
| 12 | **Genotype frequencies are closer to the BC2S2 expectation, with HET excess and introgression deficit** (user, 2026-09-24; zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §2.4). chr10, RTIGER: HET 8.5–9.1 % vs 6.25 % (BC2S2) / 3.1 % (BC2S3), TEO 4.1–6.6 % vs 9.4 % / 10.9 %; PHG (share of called ranges): HET 10.2–11.2 %, TEO 1.9–2.4 %. TEO allele fraction 8.7–10.8 % (RTIGER), 7.0–8.0 % (PHG) vs 12.5 %. Both callers agree on which lines carry introgressions and where; PHG breaks RTIGER TEO segments into TEO/HET/B73 and calls recurring short HET spikes in lines RTIGER calls all B73 | reporting (single-locus checks); stage 7 | the bulks' parent is BC2S2 (user), so BC2S2 is the expectation in reporting; the HET excess and introgression deficit are reported against it. PHG shares are reported over called ranges with the no-call share (24–30 %), RTIGER over bp |
| 13 | One low-coverage line stops the whole RTIGER run: RTIGER refuses any line × chromosome with < 2 × rigidity covered markers; PN6_SID484 had 253 (floor 1,000) | stage 2b COVERAGE_QC | **decided (user, 2026-09-24): exclude the line as in zealhmm** (`scripts/zeal_paired_cohort_coverage_qc.R`): covered marker = site with ≥ 1 read; a line with any chromosome below 2 × rigidity covered markers is excluded from **every** caller (RTIGER, PHG, the rest), not only RTIGER, and listed in `sample_qc.tsv` with its per-chromosome counts. Markers = the sites ancestry inference uses (the donor's own tier-A sites; floor 1,000 at rigidity 500). The two failed development libraries are already excluded in `meta/dev_import.csv` |

## 5. Storage, caching and cleanup (from the disk audit, 2026-09-24, job 946049)
Measured (`du -sk` / `--inodes`, one array task per directory; table `ZEAL/results/audit_du_20260924/tasks/`):

| location | size | files |
|---|---|---|
| `results/work/` (Nextflow, `--outdir ZEAL/results` runs) | 1,903 GB | 1,482 |
| `results/gate2/work/` | 1,015 GB | 1,064 |
| `results/bc2s3_batch2/work/` | 279 GB | 2,047 |
| `results/demux/` | 81 GB | 37 |
| `ZEAL/reference/` | 65 GB | 263 |
| `results/align_membench/` (pool-1B CRAMs) | 41 GB | 25 |
| `results/cram/` | 22 GB | 21 |
| `results/b73_control/` | 22 GB | 26 |
| `/share/maize/frodrig4/tmp` | 22 GB | 652 |
| `results/qcset_designB/`, `results/pilot_1B_chr10/` | 17 GB, 16 GB | 5.6K, 6.0K |
| `ZEAL/envs/`, `/share/maize/frodrig4/conda` | 15 GB, 12 GB | 49K, 160K |
| all other `results/*` (pilots, benchmarks, logs, PHG DBs 0.2–1.2 GB each) | < 10 GB each | |
| `results/stub/` | 0.3 GB | 106K |

Findings: ~3.2 of ~3.6 TB is Nextflow `work/` (few, huge files: demux FASTQs + alignment intermediates of the pool, gate-2 and
batch-2 runs), because `nextflow.config` sets `workDir = "${params.outdir}/work"` on the persistent partition. Published results are
small. The large file counts are environments and the stub run, not data.

Rules proposed for v2:
1. `workDir` on `/share/maize/frodrig4/nf_work/<run>` (2 TB, not persistent; 22 GB used today). Results published to `/rsstu`.
2. CRAMs, per-pool demux QC and step-4 tables in a `storeDir` on `/rsstu` (`ZEAL/store/{cram,demux_qc,step4}`), never in `work/`.
3. Demux FASTQs never outlive their alignment: one DEMUX+ALIGN task per library, all samples aligned, FASTQs in the task's scratch only
   (§0, Task 2); 3–4 libraries at a time fit the 2 TB scratch.
4. After each successful run: `nextflow clean -f -but <last>` and a size report; stub runs always cleaned.
5. Existing `work/` (3.2 TB): before deleting, confirm every CRAM / table the project uses is published outside `work/`
   (`results/cram`, `results/align_membench`, `results/bc2s3_batch2/cram`, the pilot dirs) — decision and check pending, nothing deleted.

## 6. Supervision
Per run: own launch dir and `workDir`; a post-run check (work size, failed tasks, published outputs); monitors, not sleep loops; long runs
watched with the session kept open (`/loop`), acting only as the run card allows.

### Testing ladder (gates, from zealbc1; climb only when the current gate passes)
- **Gate −1 · CodeRabbit** (optional, local, before push, substantive changes only): `coderabbit review --committed --base main --agent`.
  It catches code/API bugs, not environment/data bugs; every finding is checked against the code before it is applied.
- **Gate 0 · `-stub-run`** (short QOS): every module's `stub:` touches its outputs, so the whole DAG runs in seconds and proves wiring,
  channel joins and filenames. Stub `work/` is cleaned afterwards (§5 rule 4, with the user's consent).
- **Gate 1 · tiny real subset** (short QOS): real tools on toy inputs (~1M read pairs of one library, a few samples, one donor × a
  small region).
- **Gate 2 · one full unit**, the benchmark (cpu/ram/time/disk per module, recorded in `docs/REQUIREMENTS.md`). *Proposed, not
  decided:* workflow 1 = one full library (e.g. BC1_1B) on compute/normal; workflow 2 = one donor × chr10 on short QOS. Nothing
  full-scale runs before this passes.
- **Gate 3 · full run**, once Gate 2's numbers justify the allocation.

## 7. Open decisions (summary)
§4 #2, #3, #5–#7, #12; storage rules of §5; which existing CRAMs and tables are reused vs regenerated after MARKDUP.

## References
1. Huang HW, Mullikin JC, Hansen NF. Evaluation of variant detection software for pooled next-generation sequence data.
   *BMC Bioinformatics* 2015;16:235. doi:10.1186/s12859-015-0624-y
2. Van der Auwera GA, Carneiro MO, Hartl C, Poplin R, et al. From FastQ data to high-confidence variant calls: the Genome Analysis
   Toolkit best practices pipeline. *Curr Protoc Bioinformatics* 2013;43:11.10.1–11.10.33. doi:10.1002/0471250953.bi1110s43
3. Bansal V. A statistical method for the detection of variants from next-generation resequencing of DNA pools.
   *Bioinformatics* 2010;26(12):i318–i324. PMC2881398
4. Danecek P, et al. Twelve years of SAMtools and BCFtools. *GigaScience* 2021;10(2):giab008. (not re-checked this session)
