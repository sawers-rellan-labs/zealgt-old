Queued (user, 2026-09-28): implement the zealgt sample-identity registry once the source catalog
(agent/*_id_source_catalog.md + .tsv) is in. Coordinator + subagents; each writes a handover and returns a short report.

User requirements
- Keep all the information coordinated in one place, with **minimal data wrangling, read as directly as possible from the master
  sources** (the Google Drive originals: manifests / plating sheets, field books CLY23-25 with REF-all and GENOTYPE-CONVERSION, field
  maps, the BZea Sample List, the teosinte accession metadata of the donor accessions, the pedigree-string table with one column per
  generation + the readable concatenation + the short nil_id, and the others in the catalog).
- The list must serve the genotype workflow AND track ids across the other sequencing experiments (BC1 pools, BC2S3 batch 1 and batch 2,
  skim, BRB-seq, future runs): one row per sequenced sample, the well-level sample_id as the key (meta/PROVENANCE.md "Identifiers").
- Identity corrections (e.g. PN17_SID1574 → Zx.0350_P1_P2_P2.2.1.1 / Zx03501222 by field plot) are applied at the END of the pipeline,
  in the genotype tables' id translation — never by rewriting raw provenance (CRAM headers, provenance records, delivered sheets).

Design (from agent/20260928_141646_id_lineage.md and agent/20260928_142812_id_lineage_zealtiger.md; adapt to the catalog)
- meta/sources/: one exported copy per master document (xlsx or its sheet CSVs as exported from Drive), unmodified; SOURCES.tsv lists
  for each: class, Drive URL, Drive last-modified, export date, local path, sha256, used_by. Re-export = new row + new sha, old copy kept
  in git history. Laptop-only / undocumented files (J2Teo_Final_DB.csv, sample_metatada.csv) are kept as evidence only, flagged
  superseded, never read by the builder.
- meta/build_samples.py: reads only meta/sources/ files listed in SOURCES.tsv, verifies every sha256 first (refuses on mismatch), and
  does only joins and the documented pedigree → nil_id rule (checked against a tracked copy of the register); no hand-edited values.
  Batch-1 pedigree via well → field plot → REF-all (which resolves PN13_SID1226 and PN17_SID1574 from the data); carry field plot,
  field row/position, season, accession, taxon, the generation columns and the readable pedigree string, nil_id, experiment, library,
  plate/well, role, check/exclusion flags with reasons.
- meta/corrections.csv (append-only): sample_id, field, old value, new value, evidence (document + row / permalink / genotype check),
  date, who decided; applied by the genotype workflow's final id translation, not by build_samples.py's raw columns (the raw columns
  stay as delivered; a separate resolved column may show the corrected value with the correction id).
- meta/PROVENANCE.md: rewrite the Sources / Joins / Identifiers sections to describe exactly this chain, fix the two inaccuracies found
  (bc1_well_map builder is zealbc1 nilhmm/bin/make_demux_inputs.R @ bd86bda; 29 excluded plate-1/LANTEO wells are in the skim table),
  list gaps (crossing records, seed-lot records, the written nil_id rule, J2Teo's origin, the three batch-2 plots' 2024 records).
- A note for zealhmm (not an edit there): PN17_SID1574 is Zx03501222 by plot; its GWAS panel carries a pedigree that does not exist.
- Tests: a small check script (or pytest) that rebuilds samples.csv from meta/sources/ and diffs against the committed one; run it in
  scripts/run_checks.sh.
Rules: CLAUDE.md; scripts in agent/ for multi-line commands; single plain git commands; stage explicitly; no deletions; commits end with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; work on main in meta/ only (the CRAM refactor is on branch simplify, the
genotype workflow on branch genotype — tell them via main when samples.csv's columns change).
