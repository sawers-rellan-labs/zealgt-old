# Provenance of the sample metadata (2026-09-28)

`meta/build_samples.py` builds the sample-identity registry from the pinned master documents in `meta/sources/`:

| output | what |
|---|---|
| `meta/registry.csv` | one row per sequenced sample of every experiment, key `sample_id`; raw identity columns from the sources, `*_resolved` columns with `meta/corrections.csv` applied |
| `meta/samples.csv` | the sample sheet of workflow 1 (read processing): the non-excluded `bc1` / `bc2s3_batch1` / `bc2s3_batch2` rows of the registry, first 20 columns (validated by `assets/schema_input.json`) |
| `meta/accessions.csv` | donor passport data of the 227 accessions (J2Teo `metadata`), `longitude_resolved` with the corrections applied |
| `meta/corrections.csv` | append-only identity correction log (hand-maintained; never rewritten) |

Rebuild with `python3 meta/build_samples.py`; `python3 meta/build_samples.py --check` rebuilds in memory and diffs against the
committed tables (run by `scripts/run_checks.sh`, also with `--quick`). The builder is standard-library Python (`meta/xlsx_read.py`
reads the xlsx exports; cross-checked against readxl on every tab it reads, 0 differing cells, `agent/20260928_174100_compare_xlsx_reader.py`).

## Result
Registry: 2,784 samples.
- BC1: 384 (32 pools).
- BC2S3 batch 1 (CLY2023 skim): 1,632 wells (1,405 lines, 79 landrace lines, 31 checks, plus 117 wells of the other project with
  `exclude` = TRUE).
- BC2S3 batch 2: 384 (362 lines, 13 checks, 9 empty).
- BRB-seq summer 2023: 384 (345 lines, 39 checks).

`samples.csv`: the 2,283 workflow-1 rows (unchanged set and order). All sample IDs are unique, all barcodes are unique within their
library, and every sample has a raw location.

## Sources
`meta/sources/SOURCES.tsv` lists every file with its class, Drive URL, Drive last-modified time, export date, how it was obtained, sha256,
use and status. The builder reads only listed files and refuses to run on a sha256 mismatch.
- **Re-export:** add a new row for the same `file` with the new sha; the last row wins, and git history keeps the old copy.
- **User-provided exports (2026-09-28):** `CLY25-Fieldbook` and `23_NCS_PSU_LANGEBIO_FIELDS` are too large for the Drive connector;
  the user's browser exports of 2026-07-08 are pinned byte-for-byte as `drive/cly25_fieldbook.xlsx` and
  `drive/23_ncs_psu_langebio_fields.xlsx`. CLY25-Fieldbook was edited on Drive on 2026-07-20, after the export, and the pinned copy has
  not been re-checked against the current Drive version. 23_NCS was last modified on Drive on 2026-01-23, before the export.
- **Catalogued, not pinned:** CLY23_D4_FieldBook, CLY25, BZeaV2_plates and Molbreeding samples. Their exports are in
  `agent/idcat/drive_exports/` only. The master-document audit is `agent/20260928_145808_id_source_catalog.md` + `.tsv`.

| file in `meta/sources/` | role in the build |
|---|---|
| `drive/j2teo_final_db.xlsx` | **J2Teo_Final_DB** (PI-owned Google Sheet, modified 2026-07-21): the lab's master pedigree database (naming convention, 227 donor accessions with passport data, one tab per generation, `All`, `Finalized`). **`All`**: `seed_origin` → `line_id`, `old_line_id`, `accession_id`, `taxa_code`, generation columns `gen F1 BC1 BC2 S1 S2 S3 S4 blk TC`, `batch`. **`BC1`**: BC1 line → seed_origin. **`metadata`**: `accessions.csv`. CLY23 `REF-all` is an older frozen copy of `All` (8 seed_origins missing, among them PV24-1800/1887/1888 and PV23-2382) and is not read |
| `drive/bzea_library_prep_sheet_code.xlsx` | Hannah's batch-1 prep sheet (Drive file, 2025-05-19), `Sheet1`: all 1,632 wells with well, barcode, plate index, the name, **`tissue_origin`** (field plot sampled) and **`seed_origin`** (seed packet). Well, barcode and plate index agree with the delivery sheet 1,632/1,632 (checked on every build) |
| `drive/bzea_sample_list.xlsx` | DNA plating sheet (Drive file, 2026-06-24); check only: `Sample_Origin` = prep `tissue_origin` for every sequenced well except PN13_SID1225 (flagged; C0002); holds 15 PN18 wells that have no sequencing record |
| `drive/rr_23_fields.xlsx` | RR-23-Fields `Sheet12`: PV23 packet → female parent plant (`mother_plant`, batch 1 and BRB-seq) |
| `drive/zealv2.xlsx` | ZeaLV2 `ZeaL-V2_manifest`: batch-2 plate, cell, **plot**, **origin packet**, pedigree, pool, inline barcode; plates BZeaV2_1–4 (BZeaV2_5 never sequenced) |
| `drive/24_ncs_psu_langebio_fields.xlsx` | `PV24-block1`: PV24 packet → female parent plant (batch-2 `mother_plant`); `CLY24-C8A`: the batch-2 field, plot → packet and sowing instruction (checked: packet = manifest origin 384/384) |
| `drive/bzeabrb_library_prep_sheet_code.xlsx`, `drive/bzeabrb_manifest.xlsx`, `drive/bzeabrb_trimmed_read_statistics.txt` | BRB-seq summer 2023 (RNA, CLY23-D4 rep 3): prep sheet `library_prep_sheet_code` (Seq_ID, well, 14-bp barcode, i7/i5, pool, genotype, origin packet), manifest `Plate_manifest` (plate, well → CLY23-D4 plot), and the per-sample read statistics (only pool BZeaRP1 = plates 1–4 was sequenced; 5 of its 384 wells have no reads, flagged) |
| `drive/some_bzea_nomenclature_conversions.xlsx` | evidence for correction C0001 only |
| `drive/23_ncs_psu_langebio_fields.xlsx` | PV23 nursery book (co-PI account, Drive modified 2026-01-23; export 2026-07-08); **check only**. `PV23-BZea` is the master of RR-23-Fields `Sheet12`: packet → origin and female parent agree for 2,590/2,590 packets. `PV23-block4-BZea-Bulk` is the nursery record of the batch-1 tissue plots: for every batch-1 line, plot → packet (`Female parent`) and name (`Description`) equal the prep sheet's `seed_origin` and the delivered name. It differs for 26 check wells only: 25 B73 / Purple Check wells with a different check packet, and PN13_SID1225, whose prep-sheet plot PV23-8397 is a Zd line. Block4 plot PV23-8396 is `Purple Check-bulk`, which supports the Sample List in C0002. The tabs give no value the pinned sources lack, so nothing is read into the registry |
| `drive/cly25_fieldbook.xlsx` | CLY25-B5 phenotype field book (Drive modified 2026-07-20, after the 2026-07-08 export; not re-checked). Pinned as evidence and **not read**: no sequenced sample in the registry was grown in CLY25. The batch-2 plots are CLY24-C8A (read from `24_NCS…`), and `REF_BC2S3` is in the separate `CLY25` workbook |
| `register_bc2s3.csv`, `NIL_ID_README.md` | copies of the zealhmm nil_id register and its specification (untracked in zealhmm `agent/gdl_flowering/`, 2026-08-09); the README is the only written pedigree → nil_id rule; the register is a check, never a value source |
| `bc1_well_map.csv`, `bc1_libraries.csv` | BC1 pool, column, barcode, `Sample_Id`, line, donor, taxon (zealbc1 `meta/`). Built by zealbc1 `nilhmm/bin/make_demux_inputs.R` @ `bd86bda` from the replate worklist `bc1_replate.csv` (Drive `Sequencing/ZeaL BC1s/replate/`, https://drive.google.com/file/d/1rngILJY1wlzxBey65ciqAI3Zy8EhTZHu), which Hannah confirmed is what the robot ran (Slack 2026-09-28, https://rsrrjs-labs.slack.com/archives/D02HFJ71AHL/p1790616377418009; `manual_replate` was an earlier iteration and is deleted). Routing each line through the worklist reproduces the map for 384/384 wells (`agent/20260927_233403_compare_bc1_manifest.py`) |
| `bc2s3_batch1_sample_sheet.csv`, `bc2s3_batch1_tar_members.tsv` | NCSU GSL delivery sheet `BZea_Sample_ID.xlsx` (hazel `sara/DNA_Sequencing_raw/BZea/`, Dec 2023, sheet 1 as CSV) and the `tar -tvf` listing of `NVS188B_Rellan_Alvarez_R{1,2}.tar`; batch-1 sample_id, barcodes, plate index, delivered name, raw members |
| `bc2s3_batch2_libraries.csv`, `inline_barcodes.tsv` | batch-2 pool → raw directory (Novogene X202SC26093287-Z01-F001); the 12 Twist FlexPrep UHT inline barcodes (ZeaLV2 `REF-inline`) |
| `bc2s3_batch1_skim_nil_id.tsv`, `bc2s3_batch2_well_map.csv` | **superseded** derived tables (zealbc1): compared on every build, never a value source. Batch 1: 1,403 of 1,404 shared samples agree on pedigree and nil_id; the one difference is PN10_SID893, a B73 check. Batch 2: sample_id, pool and barcode agree 384/384, nil_id agrees 384/384 |
| `evidence/` | kept as evidence only, flagged superseded in SOURCES.tsv, never read by the builder: the laptop `J2Teo_Final_DB.csv` (tab `Finalized`, 2025-05-13), the BzeaSeq `sample_metatada.csv` (hazel; = zealtiger `sample_metadata_master.csv`), and the locally corrected `Bzea_metadata.csv` (evidence for the longitude corrections) |

## Joins and rules applied
- **BC1:** `bc1_well_map.csv` as is. The line is looked up in J2Teo `BC1` for the generation columns and `seed_packet` (the line's
  J2Teo seed_origin). 26 BC1 lines are not in that tab (flag `not_in_j2teo_BC1`).
- **Batch 1:** the chain is well → field plot → pedigree.
  - The delivery sheet gives `sample_id` = `PN<Plate_Number>_SID<running number>`.
  - The prep sheet (same plate + running number) gives `field_plot` (tissue_origin, PV23) and `seed_packet` (seed_origin).
  - J2Teo `All` row of the field plot gives `line_id` (bulk `.B`), the generation columns, and `pedigree` (the line: `.B` / `-blk` /
    `-bulk` dropped).
  - When the plot has no row or two rows, the seed packet's row decides (flag `tissue_plot_j2teo_rows=`). This happens for PN3_SID199
    (plot PV23-7370 is not in `All`) and PN17_SID1574 (plot PV23-8745 has two rows).
  - For all 1,405 lines where both rows exist, the plot row and the packet row name the same line.
  - Checks (B73 / Purple Check) take no J2Teo row.
  - 50 landrace wells have no J2Teo row and keep the delivered name. The other 29 landrace wells have J2Teo pedigrees (`Zm.…`).
  - `mother_plant` = RR-23-Fields `Sheet12` female parent of the packet.
- **Batch 2:** the chain is manifest well → plot (CLY24-C8A) → origin packet → J2Teo `All`.
  - `role`: `B73`/`NC358` → check, `NA` → empty, otherwise line.
  - `mother_plant` = `PV24-block1` female parent of the packet.
  - `replicate_of`: the other sequenced plots sown from the same packet. CLY24-C8A "Bulk Plant to Plant" gives three pairs, each two
    replicate plots of one NIL: P4065/P4066 (PV24-1800), P4153/P4170 (PV24-1887) and P4154/P4169 (PV24-1888). Both wells of each pair
    are kept.
  - J2Teo `All` holds all three pedigrees, so the former "derived" nil_ids are now plain rule results. They are still absent from the
    register, which was built from CLY23 REF-all + CLY25 REF_BC2S3.
- **BRB-seq:**
  - `sample_id` = `BRB_<Seq_ID>`. The lab's Seq_IDs (`PN<plate>_SID<n>`) reuse batch-1 names for other plants, e.g. BRB PN1_SID1 is
    Zd.0010, batch-1 PN1_SID1 is LANTEO067. The raw Seq_ID is in `lab_seq_id`.
  - `field_plot` = CLY23-D4 plot (manifest). `seed_packet` = origin. The pedigree comes from J2Teo `All` of the packet.
  - For 3 wells, J2Teo disagrees with the sheet's genotype (flag `sheet_genotype_differs_from_j2teo`): BRB_PN1_SID34, BRB_PN1_SID86 and
    BRB_PN4_SID309. For BRB_PN4_SID309, the zealtiger genotype match (Zx.0040, `brbseq_corrected_labels.csv`) agrees with J2Teo
    (Zx.0040_P1_P4_P1.1.1.1), not with the sheet (Zx.0370). No correction has been decided.
- **Derived columns:**
  - `donor` = `<accession>_P<F1 plant>` from the pedigree, `taxon` from its prefix, `accession` = `Zx.NNNN`.
  - `nil_id` comes from the rule in `NIL_ID_README.md`: taxon + 4-digit donor + base-36 P1 P2 P3 S1. It is set for BC2S3 and later
    generations only (S2… = 1); checks, empties and BC1 get none.
- **nil_id rule check:**
  - The rule reproduces all 2,624 register rows.
  - Every registry nil_id whose pedigree is in the register equals the register's id (0 mismatches).
  - 36 rule ids are not in the register: 6 batch-2 (the three pairs) and 30 batch-1. The 30 batch-1 ids are PN17_SID1574 (raw) and 29
    BC2S4 wells, 26 of them in the excluded plate 1. Their nil_id is `nil_id_in_register` = FALSE.
- **Batch-1 plate ↔ tar pool:** `BZea<n>` = plate *n*. Plates 1–9 carry TruSeq indexes 1–9; plates 10–17 reuse indexes 2–9 and sit on
  lanes 3–4 (plates 1–9 on lanes 1–2). Checked: `BZea6` reads carry index `GCCAAT` = plate 6's.
- **Batch-1 barcode layout:** an 8-bp inline barcode at the start of R1 only. Checked on `BZea6`: the top 96 5′ 8-mers cover 91.9% of
  reads, vs 6.6% for 6-mers at base 31. BC1 and batch 2 carry a 6-bp inline barcode on both R1 and R2.
- **Excluded — another project sequenced in the same batch-1 run** (user, 2026-09-24): all of plate 1 (96 wells) and the 21 `LANTEO…`
  wells on plates 2–17. They are in `registry.csv` with `exclude` = TRUE and a reason, and are not in `samples.csv`.
  - None of them is in `bc2s3_batch1_skim_nil_id.tsv`.
  - 29 are in the zealhmm/zealtiger `skim_sample_pedigree.csv`, with taxon-coded BC2S4 pedigrees such as PN1_SID37 =
    Zx.0120_P1_P2_P2.1.1.1.1 (project `lanteo` upstream).
- **Roles:**
  - Batch 1: `check` = B73 or purple check; `landrace_line` = names with `_BC1S3` / `_BC1S4` (samples 119–198 per the delivery README);
    `line` otherwise.
  - Batch 2 and BRB-seq: as above.
- **Batch-1 processing history (not used by zealgt, kept for comparison):** Nirwan's pipeline (github.com/nirwan1265/BZea_genotyping):
  sabre demux → Trimmomatic PE (ILLUMINACLIP 2:30:10, LEADING:3, TRAILING:3, SLIDINGWINDOW:4:15, MINLEN:36) → `sara/BZea/filtered_S/`
  (plates 2–17) → bwa mem → Picard markdup → ANGSD. zealgt re-demultiplexes batch 1 from the tars (docs/PLAN_pipeline.md §3).
  - Exact commands (github.com/nirwan1265/Mapping, `src/demultiplex_sabre.csh`, `src/qc_trimmomatic.csh`): `sabre pe -f -r -b
    <plate>.txt -u -w`; Trimmomatic 0.39 `PE -phred33 … ILLUMINACLIP:<custom adapters.fa>:2:30:10 LEADING:3 TRAILING:3
    SLIDINGWINDOW:4:15 MINLEN:36`.
  - The custom `adapters.fa` is unreadable on hazel (permission denied); asked for on Slack 2026-09-28.
  - sabre cut 8 bp from the 5′ end of **both** reads (1000/1000 R1, 998/1000 R2, raw vs filtered, job 969161). So `filtered_S/` R1
    still starts with the 12 random-primer bases (below), and R2 is clean.

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

## Identifiers: one physical key, biology in the registry (decided, user 2026-09-28)
- **The key everywhere is the well-level `sample_id`:**
  - BC1 `S_<pool>_<column>`, batch 2 `P<plot>`, batch 1 `PN<plate>_SID<n>`, BRB-seq `BRB_<Seq_ID>`.
  - It names every file (FASTQ checkpoint, CRAM, QC), the CRAM read group (`ID` and `SM` = `sample_id`, `LB` = library, `PU` =
    flowcell.lane list) and every internal table.
  - It never changes: it is where the DNA physically was.
- **Biology lives only in the registry** `meta/registry.csv` (and its workflow-1 projection `meta/samples.csv`), built by
  `meta/build_samples.py` from `meta/sources/`, tracked in git.
  - It maps `sample_id` → field plot, seed packet, mother plant, J2Teo line and generation columns, `pedigree`, short `nil_id`,
    `donor`, `accession`, `taxon`, `role`, source.
  - A relabelled well, a new export or a pedigree fix is a registry commit. No CRAM is renamed or rewritten, and line or nil ids are
    never written into CRAM headers (they would go stale).
- **Corrections are applied at the end:**
  - `meta/corrections.csv` records sample_id / entity, field, old and new value, `applies_to`, evidence (document + row + URL),
    date, and who decided.
  - The builder copies each applicable correction id into `correction_ids`.
  - Only the `*_resolved` columns (`pedigree_resolved`, `nil_id_resolved`, `donor_resolved`, accessions `longitude_resolved`) carry
    new values. Raw columns stay as the sources give them, and so do CRAM headers, provenance records and delivered sheets.
  - `applies_to`:
    - `resolved`: used in the resolved columns.
    - `flag`: noted on the row, no value changed.
    - `drive_owner`: an error in a Drive document that the builder does not read; it is reported to the sheet owner
      (`agent/20260928_181500_drive_errors_for_owner.md`), and the pinned exports are never patched.
- **Traceability:** each CRAM's provenance record (`<sample_id>.provenance.json`) holds a snapshot of its registry row (at least
  donor, line/pedigree, nil_id, taxon, role) and `code_version` (the repo commit, which also pins the registry version). A later
  registry change is visible by comparing the snapshot with the current row.
- **Translate at the edge:** the genotype workflow joins on `sample_id` internally. It writes the short `nil_id_resolved` (or the line
  id where no nil_id exists, e.g. BC1 samples) only into its final outputs: genotype tables, VCF sample names, paintings, reports.
  This is one join on the current registry at the end, and it records the registry commit it used.
- **Read groups:** one read group per sample. The lanes of a library are one pool; `PU` lists the lanes; duplicate marking reads
  flowcell/lane/tile from the read names. Per-lane read groups only if lane QC ever shows a lane effect.
- **Status (2026-09-28):**
  - The CRAM workflow already follows the key and read-group rules.
  - The provenance snapshot has `donor`, but not yet the line/pedigree and nil_id (to add on branch `simplify`).
  - The edge translation is a rule for the genotype workflow (branch `genotype`); column note:
    `agent/20260928_182000_samples_csv_change_note.md`.

## Corrections recorded (meta/corrections.csv, 2026-09-28)
| id | sample / entity | what | applies |
|---|---|---|---|
| C0001 | PN17_SID1574 | pedigree Zx.0390_P1_P2_P2.2.1.1 → **Zx.0350_P1_P2_P2.2.1.1** (nil Zx03501222). Packet PV23-2382 has the same mother plant CLY22B6-D-1055 as PV23-2371 (Zx.0350) (RR-23-Fields `Sheet12`). The prep sheet names the well JSG-RMM-LCL-536 (= Zx.0350), and the Nomenclature Conversions agree. It is a sibling well of PN17_SID1566 | resolved |
| C0002–C0003 | PN13_SID1225 | the Purple Check carries the neighbour's plot PV23-8397 and packet PV23-1871 in the prep sheet; the Sample List gives PV23-8396 | flag |
| C0004 | PN13_SID1226 | J2Teo `Finalized` sequencing_id PN13_SID1225 → PN13_SID1226 on PV23-8397. The registry joins by plot, so PN13_SID1226 gets Zd.0020_P3_P1_P2.5.1.1 = Zd00203125 from the data | drive_owner |
| C0005–C0007 | PN17_SID1574 | J2Teo `Finalized` PV23-8745 = Zx.0390; J2Teo `All` holds PV23-8745 twice; `All` PV23-2382 = Zx.0390 | drive_owner |
| C0008–C0082 | 75 accessions | J2Teo `metadata` longitude sign flipped (east). The local `Bzea_metadata.csv` fixed it without a log | resolved (accessions.csv) |

## Gaps
1. **PN18_SID1633–1647** (15 wells) are in the Sample List only, with no delivery sheet, prep row or reads; they are not in the registry.
2. **Crossing records:** the PV23 nursery book `23_NCS_PSU_LANGEBIO_FIELDS` is pinned (check only, above). Its `CLY23-D1` tab has not
   been compared yet. RR-23-Fields `CLY23-D1` has an empty row for plot 837, so the D1 genotype of the batch-2 mothers could only be
   checked through J2Teo. `CLY25-Fieldbook` is pinned from the 2026-07-08 export; the Drive edits of 2026-07-20 are not in it.
3. **Seed-lot records:** no seed inventory with lot ids or quantities was found for the PV24 packets / CLY24-C8A plots; there are only
   packet-level records (`PV24-ISO`, `PV24-Tags`, J2Teo `REF_PV24`).
4. **The written nil_id rule** exists only as the zealhmm `agent/` README (copied here). Nothing on Drive holds short nil_ids.
5. **J2Teo's origin:** it is a PI-owned Google Sheet (created 2023-12-03), with no change log. `All` = the source of CLY23 REF-all and
   ZeaLV2 `REF-J2Teo`.
6. **The three batch-2 replicate pairs** have 2024 sowing records (CLY24-C8A) but no plot-level harvest or selection record; the NIL
   identity of each pair rests on the shared packet.
7. **BC1:** 26 BC1 lines are not in the J2Teo `BC1` tab. Rubén's `BZea_BC1_384_sequencing_manifest` / design memo were not found.
   Hannah offered a BC1 barcode manifest (none exists).
8. **Field row / position** is not carried: it exists only in the map-grid tabs (RR-23-Fields, CLY24-C8A-map), which would need grid
   parsing.
9. **The builder of `bc2s3_batch1_skim_nil_id.tsv`** is lost; the table is superseded here.
10. **79 landrace BC1S3/BC1S4 lines:** confirm they belong in the ZEAL genotyping. 50 have no J2Teo row.
11. **BRB-seq:** 3 wells disagree between the prep sheet genotype and J2Teo (above). Pools BZeaRP2–4 (plates 5–15, 998 wells) were prepped
    but have no reads on Drive. The fall-2023 list (`BZeaBRB-F manifest`) has no sequencing record.
13. **Batch-C lines (`_Q` segments) collide in the nil_id rule** (checked 2026-09-29, `agent/20260929_133000_test_q_as_p.py`).
    J2Teo has 9,689 cells with a `_Q<n>` segment (BC1 tab 121, BC2 1,010, BC2S1 2,295, BC2S2 1,451, BC2S3 1,317, `All` 3,495). `_Q`
    is not a typo for `_P`: every Q row is batch **C** (2023 crosses: seed `23CLD1B73x…`, `CLY24A5C-…`, `PV24-…`; old names used `_X`,
    e.g. `CIM10003_P2_P1_X1`), and renaming Q→P gives 0 rows that describe the same plant but 1,787 names (in `All`) that already belong
    to a **different** batch-A/B plant, e.g. `Zd.0010_P2_P1_Q1` (batch C, seed 23CLD1B73x475.1) vs `Zd.0010_P2_P1_P1` (batch A, seed
    13CL6081×6082-1). `_Q` appears only at the BC1 or BC2 segment, never first, so the donor (`<accession>_P<n>`) is unaffected. The
    nil_id rule (`NIL_ID_README.md`) reads those segments by number only, so a batch-C line and a batch-A/B line with the same numbers
    get the **same nil_id**. **Confirmed by Rubén (Slack DM, 2026-09-29):** "Las Q son nuevas BC2s generadas por nosotros y decidimos
    usar Q en lugar de P para distinguirlas de las BC2s que había generado Jim"; the practical reason: Jim's P numbers are not
    consecutive within a donor and skip numbers. So `_Q<n>` and `_P<n>` are different plants, and the nil_id must encode the letter
    (encoding to be decided by the rule's owner). No sequenced sample is batch C today (registry: 0 `_Q` pedigrees), so nothing here is affected; before any
    batch-C line is sequenced or registered, the rule's owner (zealhmm register, Rubén's naming) must encode the letter. The builder
    refuses any pedigree it cannot give a donor.
12. **MolBreeding 45K:** the target-sequencing tubes (`Molbreeding samples` / `Molbreeding_manifest`) are keyed by batch-1 Seq_ID and are
    not joined yet. zealtiger found that the target-seq tube labelled PN4_SID330 is PN4_SID322 (`pn4_sid330_mislabel.qmd`).
