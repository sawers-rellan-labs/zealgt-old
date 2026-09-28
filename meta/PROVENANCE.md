# Provenance of the sample metadata (2026-09-24)

`meta/samples.csv` — the single sample sheet of workflow 1 — is built by `meta/build_samples.py` from the tables in `meta/sources/`,
copied into this repo on 2026-09-24. This file records where each source came from, how it was made, and what is still unresolved.
Rebuild with `python3 meta/build_samples.py` (it validates and exits 1 on a failed check).

## Result
2,283 samples in 80 libraries: BC1 384 (32 pools); BC2S3 batch 1 1,515 (16 plate pools: 1,405 lines, 79 landrace lines, 31 checks);
BC2S3 batch 2 384 wells (32 rows: 362 lines, 13 checks, 9 empty). All sample IDs unique; all barcodes unique within their library;
every sample has a raw location.

## Sources
| file in `meta/sources/` | what | origin | how it was made |
|---|---|---|---|
| `bc1_well_map.csv` | BC1: pool, column, barcode, `Sample_Id` (`S_<pool>_<col>`), BC1 line, donor, taxon (384) | zealbc1 `meta/bc1_well_map.csv` | built in zealbc1 from the BC1 sequencing manifest of `bzea-bc1-reference` (`meta/samples.tsv`, `docs/BZea_BC1_384_sequencing_manifest.csv`; Rubén) and the 12 inline column barcodes; builder not tracked. **Primary source on Drive** (shared drive, `Sequencing/ZeaL BC1s/replate/`): Google Sheet `manual_replate` (https://docs.google.com/spreadsheets/d/1cnPzCN9HFIEaA-mITT013VSaYj1OKZe8EyNEKiVNfbc, modified 2026-07-31; 384 rows: BC1_line_id, F1_line_id, src_plate/src_well → dst_plate/row/col) and the liquid-handler worklist `bc1_replate.csv` (https://drive.google.com/file/d/1rngILJY1wlzxBey65ciqAI3Zy8EhTZHu, 2026-07-31; same transfers as `8_3_26_BC1_Replate.xlsx`, 2026-08-03). Pool = `<dst_plate><dst_row>`, column = dst column. Routing each line from its source well through the worklist reproduces `bc1_well_map.csv` for **384/384** wells (line id, donor = F1_line_id, taxon from the Zx/Zv/Zd/Zl/Zh prefix, barcode per column); the `dst_*` columns of `manual_replate` itself agree for only 56/384, because the worklist orders source wells as unpadded strings (`D10` before `D2`); the map follows the worklist, i.e. what the robot did (`agent/20260927_233403_compare_bc1_manifest.py`, 2026-09-27). **Confirmed by Hannah** (Slack DM, 2026-09-28): "It was `bc1_replate.csv` / `8_3_26_BC1_Replate.xlsx`, not what's in manual replate" (https://rsrrjs-labs.slack.com/archives/D02HFJ71AHL/p1790616377418009); `manual_replate` was an earlier iteration made under the robot's constraints, and she has deleted it from Drive (https://rsrrjs-labs.slack.com/archives/D02HFJ71AHL/p1790616874843469), so its link above no longer resolves. `bc1_well_map.csv` stands as is |
| `bc1_libraries.csv` | BC1 pool → raw directory name (1A = `BC1_1Ar`, a re-delivery) | zealbc1 `meta/` | raw data `BZea/BC1_dna_raw/01.RawData/` (Novogene; 4B re-demultiplexed by the center, 2026-09-03) |
| `inline_barcodes.tsv` | the 12 BC1 / batch-2 inline column barcodes (6 bp, same on R1 and R2) | zealbc1 `meta/` | Hannah's Google Sheet (sent in Slack 2026-09-21, https://docs.google.com/spreadsheets/d/1aAjkTqVYN4uBqzG-b8sgR2BF6YtXA5WQ9vGTsNj7Fy8/edit?gid=0) downloaded as `zealbc1/meta/ZeaLV2.xlsx`, sheet `REF-inline`; the 12 sequences are Twist FlexPrep UHT's inline barcodes (Twist demux guide DOC-001509, read structure `6B2S+T` on both reads; `agent/20260927_231439_twist_96plex_guide.md`). The same workbook holds the batch-2 manifest but no BC1 pool map (checked 2026-09-28) |
| `bc2s3_batch2_well_map.csv` | batch 2: row, column, barcode, `Sample_Id` (`P<plot>`), label, nil_id (+ source), check flag, class, taxon, plot, pedigree, donor, plate, cell (384) | zealbc1 `meta/` (decisions 2026-09-21) | Hannah's Google Sheet → `zealbc1/meta/ZeaLV2.xlsx` (sheet ZeaL-V2_manifest) → `bc2s3_batch2_manifest.csv`, restricted on 2026-09-23 to the 4 sequenced plates BZeaV2_1–4 (plate BZeaV2_5 was never and will never be sequenced); nil_id from the zealhmm register, 3 pedigrees missing from it given nil_ids derived by the register's rule |
| `bc2s3_batch2_libraries.csv` | batch-2 row → raw directory | zealbc1 `meta/` | raw data `BZea/BC2S3_batch_2_dna_raw/01.RawData/` (Novogene X202SC26093287-Z01-F001, delivered 2026-09-15) |
| `bc2s3_batch1_sample_sheet.csv` | batch 1 (CLY2023): well, barcode (8 bp, R1), library, plate, plate index (TruSeq 6 bp), running number, genotype (1,632 wells) | `sara/DNA_Sequencing_raw/BZea/BZea_Sample_ID.xlsx` (delivery document, Dec 2023; read-only) | converted to CSV on 2026-09-24 (sheet 1, no edits) |
| `bc2s3_batch1_tar_members.tsv` | the FASTQ members (size, path) of `NVS188B_Rellan_Alvarez_R{1,2}.tar` | `sara/DNA_Sequencing_raw/BZea/` (NovaSeq S4 2×150 run NVS188B, June 2023; owner ntanduk; 753 + 765 GB, read-only) | `tar -tvf` on 2026-09-24: 17 plate pools `BZea1`–`BZea17` × 2 lanes × R1/R2 |
| `bc2s3_batch1_skim_nil_id.tsv` | batch-1 `PN<plate>_SID<n>` → nil_id, pedigree (1,418) | zealbc1 `agent/skim_sample_nil_id.tsv` | derived from the zealhmm correspondence tables (`data/zeal/correspondence/skim_sample_pedigree.csv`, `sample_metadata_master.csv`); builder not tracked |

## Joins and rules applied
- **Batch-1 plate ↔ tar pool:** `BZea<n>` = plate *n*. Plates 1–9 carry TruSeq indexes 1–9; plates 10–17 reuse indexes 2–9 and sit on
  lanes 3–4 (plates 1–9 on lanes 1–2). Checked: `BZea6` reads carry index `GCCAAT` = plate 6's.
- **Batch-1 sample ID:** `PN<Plate_Number>_SID<Sample_ID running number>`; matches 1,404 of the 1,418 samples of the skim map
  (spot checks: PN7_SID590 = Zd.0040, PN3_SID220 = Zx.0100, PN15_SID1438 = Zv.0490, PN10_SID893 = B73).
- **Batch-1 barcode layout:** 8-bp inline barcode at the start of R1 only (checked on `BZea6`: the top 96 5′ 8-mers cover 91.9% of reads
  vs 6.6% for 6-mers at base 31). BC1 and batch 2: 6-bp inline barcode on both R1 and R2.
- **Excluded — another project sequenced in the same batch-1 run** (user, 2026-09-24): all of plate 1 (96 wells, `LANTEO…_BC2S4-bulk`)
  and the 21 `LANTEO…` wells on plates 2–17. None of them is in the skim map.
- **Roles:** batch 1 — `check` = B73 or purple check; `landrace_line` = names with `_BC1S3` / `_BC1S4` (incl. colour-suffixed `…_BC1S4_black-bulk`) (traditional-variety introgressions, samples
  119–198 per the delivery README); `line` otherwise. Batch 2 — from its `class` column (`line`, `B73`/`NC358` → check, `empty`).
- **Donor / taxon** for batch 1 from the skim-map pedigree (`<accession>_P<n>` → Zd/Zx/Zv/Zl/Zh); BC1 and batch 2 from their maps.
- **Batch-1 processing history (not used by zealgt, kept for comparison):** Nirwan's pipeline (github.com/nirwan1265/BZea_genotyping):
  sabre demux → Trimmomatic PE (ILLUMINACLIP 2:30:10, LEADING:3, TRAILING:3, SLIDINGWINDOW:4:15, MINLEN:36) → `sara/BZea/filtered_S/`
  (plates 2–17) → bwa mem → Picard markdup → ANGSD. zealgt re-demultiplexes batch 1 from the tars (docs/PLAN_pipeline.md §3).
  Exact commands (github.com/nirwan1265/Mapping, `src/demultiplex_sabre.csh`, `src/qc_trimmomatic.csh`): `sabre pe -f -r -b <plate>.txt
  -u -w`; Trimmomatic 0.39 `PE -phred33 … ILLUMINACLIP:<custom adapters.fa>:2:30:10 LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36`.
  The custom `adapters.fa` is unreadable on hazel (permission denied); asked for on Slack 2026-09-28. sabre cut 8 bp from the 5′ end of
  **both** reads (1000/1000 R1, 998/1000 R2, raw vs filtered, job 969161), so `filtered_S/` R1 still starts with the 12 random-primer
  bases (below) and R2 is clean.

## Library kits, sequencing and read structures (2026-09-28)
Two different Twist kits; the read structure is a per-source parameter of DEMUX, never hard-coded.

| source | library kit | chemistry | read structure | sequenced |
|---|---|---|---|---|
| BC2S3 batch 1 (CLY2023) | Twist **96-Plex** Library Prep Kit (made in-house by Hannah) | random priming with two primers: A = well barcode 8 nt + 12-nt randomer, B = 8-nt randomer + tail with the 6-bp i7 plate index (TruSeq LT 1–12) | R1 `8B12S+T`, R2 `8S+T`: demux on R1[0:8], then crop 20 bp from R1 and 8 bp from R2 | NC State Genomic Sciences Lab (project NVS188B), NovaSeq 6000, 2 × 151 |
| BC1 pools 1A–4H | Twist **FlexPrep UHT** Library Prep Kit (part 109220, "UDI primers, TS") — inferred, see evidence | adapter ligation; same 6-bp inline barcode on both ends; UDI i5/i7 per pool | `6B2S+T` on both reads (6-bp barcode + 2 bp phasing / A-T ligation junction): 8 bp off each read | Novogene USA, contract H202SC26080522, batch X202SC26080522-Z01-F001, NovaSeq X Plus 25B, PE150, premade lanes |
| BC2S3 batch 2 (V21–V24) | Twist FlexPrep UHT (as BC1; inferred) | as BC1 | `6B2S+T` on both reads | Novogene USA, order X202SC26093287-Z01-F001, NovaSeq X Plus, PE150 |

Evidence:
- **Kit documents:** Twist 96-Plex demultiplexing guide DOC-001283 Rev 1.0 (Fig. 2 p2; read structures p6; barcode list p15) and FlexPrep
  UHT demux guide DOC-001509 (Fig. 3 p4; structure p7); notes and PDF in `agent/20260927_231439_twist_96plex_guide.md`. Neither gives adapter
  sequences; the plate/UDI indexes are TruSeq-type, so Trimmomatic uses TruSeq3-PE-2.fa (a parameter) until Nirwan's `adapters.fa` is known.
- **Batch 1 = 96-Plex:** Hannah's Slack messages (library prep sheet `BZea Library Prep Sheet Code.xlsx`, 2023-07-13; sent for sequencing
  2023-05-23); the sample sheet's barcodes are Twist's 96-Plex list (A01 `CGTACGTA`); raw reads (plate 5 lane 1, job 969161) are 151 bp, 92.2 %
  start with an exact plate-5 well barcode, R1 bases 9–20 and R2 bases 1–8 are primer-derived: aligned to B73 chr10 (job 969188, minimap2)
  they are 5′-clipped in 70 % / 51 % of reads with mismatch falling from 25 % / 24 % to background at R1 base 21 / R2 base 9
  (`agent/20260927_235700_rawtar_chr10_alignment_test.md`, `agent/20260928_120300_rawtar_structure_test.md`,
  `agent/20260927_235500_randomer_test.md`).
- **BC1 / batch 2 = FlexPrep UHT:** not written against BC1 anywhere; inferred from the Twist invoice (Aug 2026, FlexPrep UHT part 109220 with
  UDI primers TS), the batch-2 QC memo ("FlexPrep/EF-style"), the 12 inline barcodes = FlexPrep's list, and the reads: after the 6-bp barcode
  both mates start with a fixed `CT` (99.9 % of reads, BC1 CRAM S_2A_11), the documented 2-bp junction. zealbc1's demux removed only the
  6-bp barcode, so its BC1 CRAMs carry those 2 bases. Per-pool UDI kit wells: shared-drive sheet "BC1 concentrations and adapter info" (tab
  `adapters`, folder `Sequencing/ZeaL BC1s/`).
- **Provider documents:** Slack `agent/20260927_230549_slack_sequencing_provenance.md`; Gmail `agent/20260927_230917_gmail_sequencing_provenance.md`;
  Novogene release in `BZea/BC1_dna_raw/` (`Readme.html`, `02.Report_…zip`, `MD5.txt`; md5 check 243/243, job 651495) —
  `agent/20260927_233737_novogene_download_doc.md`.

## Development import sheet (`meta/dev_import.csv`, 2026-09-24)
The existing CRAMs zealgt's development entries start from (docs/PLAN_pipeline.md §0), read in place from `ZEAL/results/` (written by
zealbc1 / nilhmm) — not copied. 96 rows: per donor (`import_set` Zx.0540_P3, Zx.0570_P2) 5 BC1 samples (`results/cram/`, nilhmm pool_run
ALIGN) and 40 / 44 BC2S3 batch-1 lines (`results/bench_zx05{40,70}_chr10/bc2s3_realign/cram/`, zealbc1 `PHG/bin/bc2s3_realign.sbatch`),
plus the 2 B73 controls (`results/b73_control/`: ERR3288215 CRAM, skim10 BAM). Made from `ls -l` on hazel
(`meta/sources/dev_import_listing_20260924.txt`) joined to `meta/samples.csv`; every file has its index, every sample is in the sheet, donors
agree. All were aligned with minibwa -x sr, MAPQ 20, `-F 0x904`, **no duplicate marking, no read groups** (`dup_marked`, `read_groups`
columns), so the import step is MARK_DUPLICATES + read groups, not realignment. Development runs on chr10 only (user, 2026-09-24). Excluded (`include` = FALSE, user 2026-09-24): PN6_SID484 (57,596 mapped reads) and PN8_SID736 (196,992) — failed libraries, ~1% and
~3% of a normal line (~6.5M; idxstats job 949252); PN6_SID484 also fails the zealtiger coverage QC, PN8_SID736 passes it. Development
uses 94 files: 5 + 39 (Zx.0540_P3), 5 + 43 (Zx.0570_P2), 2 B73 controls. Open: B73 control read groups not checked.

## Unresolved
1. **PN18 (14 samples, PN18_SID1633–1647)** are in the skim map but not in `BZea_Sample_ID.xlsx` (17 plates): a plate 18 from another
   sequencing run? Its raw data location is unknown.
2. **2 batch-1 teosinte lines without a nil_id** (in the sheet, not in the skim map): PN13_SID1226 (`Zdip-JSG-RMM-LCL-551_P3_P1_P1_P2.5.1.1-bulk`), PN17_SID1574 (`Mesa-JSG-Y-RMM-444_P2_P1_P1_P2.2.1.1-bulk`).
3. **Landrace BC1S3/BC1S4 lines (79):** part of this delivery; confirm they belong in the ZEAL genotyping.
4. The builders of `bc1_well_map.csv` and `bc2s3_batch1_skim_nil_id.tsv` are not in any repository. `ZeaLV2.xlsx` (Hannah's sheet) is
   not the BC1 source: no BC1 pool, line id or donor of `bc1_well_map.csv` appears in it (2026-09-28). BC1 is now traced to Drive
   (2026-09-27): `manual_replate` (https://docs.google.com/spreadsheets/d/1cnPzCN9HFIEaA-mITT013VSaYj1OKZe8EyNEKiVNfbc, 2026-07-31) routed
   through the worklist `bc1_replate.csv` (https://drive.google.com/file/d/1rngILJY1wlzxBey65ciqAI3Zy8EhTZHu) matches all 384 wells
   (line, donor, taxon, barcode; 0 mismatches). (a) Resolved 2026-09-28: the sheet's own `dst_*` layout differs from the worklist for 328
   wells, and Hannah confirmed the worklist (`bc1_replate.csv` / `8_3_26_BC1_Replate.xlsx`) is what was run on 2026-08-03 and deleted
   `manual_replate` (https://rsrrjs-labs.slack.com/archives/D02HFJ71AHL/p1790616377418009), so `bc1_well_map.csv`, the demux sample names and
   the BC1 CRAMs' sample identities need no change; she also offered to make a BC1 barcode manifest (none exists; not requested yet).
   Still open: (b) Rubén's `BZea_BC1_384_sequencing_manifest` /
   `BZea_BC1_sequencing_design_memo` were not found on Drive; (c) the `bc2s3_batch1_skim_nil_id.tsv` builder is still untracked.
