# Handover: registry snapshot in the provenance record (meta/PROVENANCE.md "Identifiers"), branch `simplify`, 2026-09-28 20:50

Base: 8a63c7c (merge of origin/main with the Identifiers rule). Not pushed; no CodeRabbit; no hazel.

## Commits
- `5a1ffa7` Provenance record: registry snapshot of the sample's meta/samples.csv row
- this handover (`git add -f`)

## Design as built
- **Record field `registry`** (top level, after `donor`): `{file, code_version, row, note}`.
  - `file` = `--input` relative to projectDir when inside it (`meta/samples.csv`, tests: `tests/fixtures/samples_test.csv`), else absolute.
  - `code_version` = commit at which the row was read: demux origin -> the checkpoint row's `stage1_code_version` (same value in the
    chained run and in read_alignment); markdup_import -> this run's `code_version`.
  - `row` = `zgRegistryFields()` = sample_id, source, role, library, plate, well, donor, taxon, nil_id, pedigree, is_check (names as in
    samples.csv / schema_input.json), all strings via `zgCell`. Technical columns (raw_*, barcodes, barcode_layout, library_index,
    rg_lb, rg_pl) are not in `row`: they are already in origin / read_group.
  - `note` = '' or `sample_id not in the registry` (row null; markdup_import only).
- **Checkpoint samplesheet**: new columns after `taxon`: `plate, well, nil_id, pedigree, is_check, registry_file` (choice: explicit
  columns, not a JSON cell — zgCsvLine refuses quotes, and plain columns stay readable). assets/schema_checkpoint.json: the five
  registry columns are **untyped** (as in schema_input.json): nf-schema infers integer for `well` "1" and boolean for "FALSE" and then
  rejects `"type": "string"` (first attempt failed exactly so). `registry_file` string, required. Checked on meta/samples.csv: no
  numeric value with leading zeros / decimals in plate or well, no quotes or commas in any snapshot column, so the inference loses
  nothing except the spelling of is_check (`FALSE` -> `"false"`; documented in docs/output.md).
- **markdup_import**: `zgRegistryRows()` reads `--input` (whole registry, nf-schema) and looks each imported `sample_id` up
  (94 of 96 dev_import rows are in samples.csv; the 2 SRA/skim B73 controls are not -> row null + note). The import sheet's own row is
  kept as `origin.import_sheet_row` (all import columns as strings, `read_groups` from meta key `read_groups_sheet`, path/index as given).
- `zgProvenanceRecord(settings, meta, store_dir, origin, read_group, registry)`: new last argument. meta is unchanged (no nil_id /
  pedigree in meta: meta is hashed by every task; only PROVENANCE's `record` input changes).
- **CRAM headers verified, not changed**: zgReadGroup gives ID = SM = sample_id, LB, PL, PU only; local real CRAMs: exactly one @RG,
  no donor / pedigree / taxon string anywhere in the header.

## Checks (logs in agent/)
- `scripts/run_checks.sh` full: lint 280 passed / 10 warnings / 0 failed; schema lint ok; nextflow lint 43 files no errors (6 warnings,
  pre-existing); nf-test 18/18; check_resources 24 rows 0 problems -> `20260928_203000_run_checks.txt`.
- nf-test snapshots updated (`20260928_201000_nftest_update3.txt`, then a clean non-update pass `_verify.txt`): the three pipeline
  tests now snapshot the provenance JSONs' registry parts (the JSONs themselves stay in .nftignore: run fields). read_demultiplexing:
  [name, "registry file: ...", row, note] (code_version omitted: HEAD); read_alignment: full `registry` (code_version = the hand
  sheet's `test`), hand sheet has the new columns, LX_1 with nil_id `Zx9000001`, LX_2 without, asserted; markdup_import: import row
  (minus path/index) + registry file/row(null)/note. The registry file is prefixed "registry file: " so nf-test does not md5 it as a path.
- Local real runs (`20260928_202000_local_runs_registry.sh`, log `.txt`, dir `20260928_202000_localrun/`): chained 24 tasks SUCCESS;
  read_alignment from its checkpoint with fresh store 13 tasks SUCCESS; for LX_1..3 `registry` identical in both records; top-level
  keys differing: cram_bytes, entry, record_written_utc, session_id, store_dir (as before).
- `scripts/test_cache.sh local` on 5a1ffa7: **RESULT: PASSED**, R2 24 of 24 CACHED; R3 stage 1 10/10 cached, ALIGN_MARKDUP 3/3
  re-executed (script only); R4 13 tasks. Console `20260928_204500_test_cache_local.txt`, summary `cachetest/20260928_143912/summary.txt`.

## Open points
- No fixture row has a nil_id (BC1-like); the non-empty nil_id path is covered only by the read_alignment stub test's hand sheet.
- `is_check` is recorded as `true`/`false` (nf-schema boolean), not the CSV's `TRUE`/`FALSE`. If the exact CSV spelling matters,
  read the registry text directly for the snapshot (not done: every other field goes through nf-schema too).
- Checkpoint samplesheets written before 5a1ffa7 lack `registry_file` and fail validation in read_alignment (none exist outside the
  local scratch: simplify has not run on hazel); rerun read_demultiplexing or add the columns by hand.
- markdup_import now validates the whole `--input` registry as well; a registry that fails schema_input.json blocks imports too.
- R3 of the cache test reruns PROVENANCE (input record: code_version changes with the clone's commit) — pre-existing, and the
  registry snapshot's code_version follows the same rule.
- Shell-rule slips: one heredoc in the terminal (python edit script `20260928_200000_edit_registry_snapshot.py` written via
  `cat <<EOF`), one `sed && grep` chain and one `cd && bash ... ; tail` style chains in the terminal; no other effect.
- Scratch left for the user (removal only with consent): `agent/20260928_202000_localrun/`, `agent/cachetest/20260928_143912/`.
