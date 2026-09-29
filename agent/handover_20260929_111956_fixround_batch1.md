# Handover: batch-1 fix round + registry snapshot from meta/registry.csv, branch `simplify` (2026-09-28/29)

Base 72549ad. Commit **b08b8d3** (code, fixtures, tests, docs) + this handover. Not pushed; no CodeRabbit; no hazel access used.

## What changed (b08b8d3)
- **G1 TRIMMOMATIC empty well:** `nf-core modules patch trimmomatic` regenerated (old diff: `agent/20260928_161000_trimmomatic.diff.prev`,
  script `agent/20260928_161000_patch_trimmomatic.sh`, tracked with -f). The functional patch adds `${task.ext.args3}` right after
  `-summary`, before the inputs (commented Groovy). `conf/modules.config`: `ext.args3 = '-phred33'`. `zgCheckpointRecord`:
  `trimming.phred = 'phred33'`. Module nf-test (real trimmomatic, `agent/20260928_162000_nftest_trimmomatic.sh`): 4/4 passed on the
  unchanged snapshots, and `.command.sh` shows `-phred33` before the inputs. Local real run: empty well PB1_SID4 →
  `TrimmomaticPE: Completed successfully`, and a CRAM with 0 reads, which then went through every tool.
- **G2 subsample I/O:** DEMUX's `--subsample` branch is now `tar -xOf|cat … | pigz -dc | head | pigz -1 -p ${task.cpus} > <lane>_R?.fastq.gz`.
  cutadapt therefore always reads a real `.fastq.gz`, in both the tar and the plain-FASTQ (BC1) paths, and in both subsample
  and full runs. The BC1 plain path was checked with a real subsample DEMUX test and the cache test.
- **G9:** a `trap 'rm -f <lane>_R{1,2}.fastq.gz' EXIT` replaces the post-cutadapt `rm`. The extracted copies now go even
  when cutadapt fails. **No `--occurrence=1`**: it is GNU-only, the laptop's bsdtar lacks it, and the audit measured its
  benefit at 0.07 s. The reason is in the module header. The DEMUX hash changes once, bundled with G2.
- **G3 PU:** `meta/build_samples.py` has a new column `rg_pu` after `rg_pl`.
  - Batch 1: `FLOWCELL_B1 = 'H7HYFDSX7'`, commented with the header evidence, plus the lanes from the tar members, e.g.
    `H7HYFDSX7.1,H7HYFDSX7.2` for plates 2–9 and `.3,.4` for 10–17.
  - Every other source: empty.
  - `rg_pu` is added to the per-library agreement loop.
  - `registry.csv` (52 cols) and `samples.csv` (**21 cols now**) were rebuilt by the builder, and `--check` passes.
  - `assets/schema_input.json`: `rg_pu` pattern `^[A-Za-z0-9.,]*$`.
  - `zgDemuxInputs`: `pu = rg_pu ?: zgPlatformUnit(names)`, and `rg_pu` is in the agreement check.
  - Local CRAM @RG: `PU:TESTFCB1.1,TESTFCB1.2`.
- **G4:** the lane is the member name minus `_R1_<nnn>`, e.g. `BZea5_S5_L001`. Each tar member pair must be `_R1_<nnn>` /
  `_R2_<nnn>` of one lane, else the library is refused.
- **Registry snapshot (task 2):**
  - New param `--registry` (default `meta/registry.csv`; schema + `.nf-core.yml` config_defaults ignore). It is read as
    text by `zgReadCsv` (quote-aware, CRLF).
  - `registry = {file, code_version, row, resolved, note}`:
    - `row` = 38 raw columns (`zgRegistryFields`: identity + J2Teo generation + field / packet / mother + exclude / flags) in
      the registry's spelling (`FALSE`, not `false`);
    - `resolved` = `pedigree_resolved`, `nil_id_resolved`, `donor_resolved`, `correction_ids`, kept apart from the raw values;
    - a sample without a registry row has row and resolved null, plus a note.
  - Technical columns are not in the snapshot: raw_*, barcodes, library_index, rg_*.
  - The registry row must agree with `--input` on source and library.
  - Checkpoint samplesheet: `plate, well, nil_id, pedigree, is_check` are replaced by `registry_note` + `reg_<column>` × 42
    (`assets/schema_checkpoint.json`, untyped, each with its own meta key).
  - `zgReadCheckpointSheet` validates with nf-schema, then takes the cell **text**. This removes the old `FALSE` → `false` open
    point.
  - markdup_import looks samples up in `--registry`.
- **Fixture (G8):** `agent/20260928_163000_make_batch1_fixture.py` (tracked with -f; deterministic) writes:
  - `tests/fixtures/raw/LIBB1/R{1,2}.tar`: ustar, 2 lane members per read, `LIBB1_R?/LIBB1_S1_L00{1,2}_R?_001.fastq.gz`, 100 bp reads,
    R1 = barcode8 + N12 + chrA, R2 = N8 + rc(chrA). Per lane: 30/20/10/0 pairs in 4 wells plus 8 unassigned;
  - `tests/fixtures/registry_test.csv`: PB1_SID3 carries a correction; PB1_SID4 is a B73 check;
  - `samples_test.csv`: the `rg_pu` column and the LIBB1 rows.
- **Tests:**
  - DEMUX: a LIBB1 stub test, plus 3 `demux_real` tests (not in run_checks, which runs `--tag stub`):
    - full lane: counts [30, 20, 10, 0], input 68 / output 60, every R1 80 bp ⊂ chrA and every R2 92 bp ⊂ rc(chrA) (= raw[20:] /
      raw[8:]), mates in step, extracted members gone;
    - tar subsample 20 → 10 pairs;
    - BC1 subsample 100 → 50 pairs.
  - Pipeline: a new stub test `--libraries LIBB1` (30 tasks, lanes `LIBB1_S1_L001/L002`, PU, tar members, phred33, raw vs
    resolved, snapshot).
  - read_alignment hand sheet: new columns; LX_2 is now "not in the registry".
  - Snapshots updated; the diff was reviewed and holds only registry file / row / resolved changes plus the new test.
- **Docs:**
  - REQUIREMENTS §4: one ALIGN_MARKDUP memory model = the calibration, as bullets (kill at 95 %, peak = M + sort, M 10 / 17–22.5 /
    design 26 GiB, history + cost, the rule as applied on simplify). The duplicate note in "Notes from Gate 2" is cut to the time
    line.
  - CHANGELOG: the cleanup-file line from the cleanup_waves handover, plus Added / Fixed lines for this round.
  - usage.md: `rg_pu`, `--registry`, and the checkpoint columns.
  - output.md: the snapshot fields.
  - PROVENANCE.md: 21 columns and the status line.
  - hazel-debug-loop SKILL: an "End-of-run cleanup file" bullet under Watching + safety.

## Checks (logs in agent/)
- `run_checks.sh` full (ZG_CHECK_PATH laptop, NXF 26.04.6): **all checks passed**. Registry --check ok; nf-core lint 0 failed;
  schema lint; nextflow lint 43 files, 0 errors; ext.args ok; nf-test stub 20/20; check_resources 46 rows, 0 problems.
  Log: `agent/20260928_165000_run_checks_full1.txt`.
- Real DEMUX nf-tests 3/3: `agent/20260928_164000_nftest_demux_real.txt`.
- Local runs (`agent/20260928_171000_local_runs_fixround.sh`, logs `_stub.txt` / `_real.txt`, dir `agent/20260928_171000_localrun/`):
  - Stub, all SUCCESS: LIBX 24 tasks, LIBB1 30, read_alignment LIBB1 17, markdup_import 10 (LX_1 row found, IMP_A null).
  - Real chained LIBX: 24 tasks.
  - Real chained LIBB1: 30 tasks. Demux summary: 136 in, 120 assigned, `samples_zero_pairs` = PB1_SID4.
  - Real read_alignment LIBB1 from the checkpoint, fresh store: 17 tasks. The registry snapshot is identical to the chained records
    for all 4 samples. The differing keys are the run fields only (entry, session_id, store_dir, record_written_utc; cram_bytes
    for 2).
  - CRAM headers: one @RG with PU; no line or nil id.
  - Real LIBB1 `--subsample 40` (store / checkpoint `subsample_40`): 40 in, 40 assigned.
- `scripts/test_cache.sh local` on b08b8d3: **RESULT: PASSED**.
  - R2: 24/24 cached.
  - R3: stage 1 all cached; ALIGN_MARKDUP re-executed (script).
  - R4: 13 stage-2 tasks.
  - Log `agent/20260928_181000_test_cache_local.txt`, summary `agent/cachetest/20260928_161358/summary.txt`.

## Batch-1 Gate 1 on hazel (one plate; replaces the audit's Gate 1 + Gate 2 proposal)
Prerequisites:
- The coordinator pushes `simplify` (b08b8d3 or later).
- A hazel checkout of that commit is named with `ZG_REPO`, e.g. `/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-simplify` (to be
  created by the coordinator/user; git-only transfer, hazel-debug-loop).
- The DEMUX / TRIMMOMATIC envs are unchanged (no environment.yml edit).
- The memory rule "CodeRabbit before data runs" applies before this real-data run.

Command, run from the laptop (the run_id names the work dir `/share/maize/frodrig4/nf_work/simplify_b1g1`):
```
ssh hazel 'ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-simplify sbatch --export=ALL /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-simplify/scripts/submit_head_job.sbatch simplify_b1g1 -profile hazel,short --workflow cram --entry read_demultiplexing --libraries BZea5 --subsample 4000000 --store /share/maize/frodrig4/nf_work/simplify_b1g1/store/subsample_4000000 --fastq_checkpoint /share/maize/frodrig4/nf_work/simplify_b1g1/checkpoint/subsample_4000000 --outdir /share/maize/frodrig4/nf_work/simplify_b1g1/results'
```
- Guards:
  - both the store and the checkpoint are named `subsample_4000000`;
  - the checkpoint is on /share, the filesystem of work/, so the hardlinks work;
  - BZea5 is not in the registry seed or the store registry, so no `--force_demux`;
  - the `--max_libraries` bound counts only dirs under that checkpoint root.
- Expected: 2 DEMUX lane tasks (`BZea5.BZea5_S5_L001`, `…_L002`, 2 M pairs each); then MERGE_LANES, DEMUX_QC, 96 × (TRIMMOMATIC,
  FASTQC, ALIGN_MARKDUP, SAMTOOLS_STATS, PICARD, PROVENANCE), REGISTRY, MULTIQC.
- What to check:
  - `store/subsample_4000000/demux_qc/BZea5.summary.tsv`: assignment ≈ 0.92, `samples_zero_pairs` empty or PN5_SID390;
  - `read_start.tsv`: R1 positions 1–10 GC ≈ 0.46–0.50, R2 without the G-depleted 1–8 block;
  - the cutadapt log's µs/read (G5);
  - DEMUX / ALIGN_MARKDUP peak_rss (G6);
  - CRAM @RG `PU:H7HYFDSX7.1,H7HYFDSX7.2`;
  - provenance `registry.row` / `.resolved` and `origin.tar_members_r*`;
  - `trimming.phred` = phred33;
  - `pipeline_info/cleanup_simplify_b1g1.sh`.
- If `ssh … sbatch` does not pass `ZG_REPO` through (the environment of a non-interactive ssh), put `export ZG_REPO=…` in a
  one-line wrapper in the job's agent dir instead.

## Open points
1. **`samples.csv` has 21 columns now** (`rg_pu`). Main's note `agent/20260928_182000_samples_csv_change_note.md` says 20.
   Tell the genotype branch: `registry.csv` has 52 columns, and `rg_pu` sits after `rg_pl`. Their reads are by column name.
   `registry.csv` / `samples.csv` now contain quoted cells (`"H7HYFDSX7.1,H7HYFDSX7.2"`).
2. **Snapshot column choice:** 38 raw columns (every non-technical registry column except the resolved four) is my decision.
   If fewer are wanted, edit `zgRegistryFields` and the schema (script `agent/20260928_160000_edit_checkpoint_schema.py`).
   A checkpoint samplesheet written before b08b8d3 fails read_alignment validation. None exist on hazel for simplify.
3. **`set +o pipefail` in the subsample branch** (pre-existing) masks a failing `tar` / `pigz -dc` upstream of `head`. Found here:
   the laptop's gzip-based pigz shim rejected `-p` and exited 0, which gave an empty lane with no error. The real pigz exits
   non-zero on a bad option, so hazel is fine. A guard (fail on 0 input pairs) was not added.
4. **The laptop pigz shim** in the main checkout's `agent/localbin` rejects `-p`. Real runs here used
   `agent/localbin_pigzp/pigz` (worktree, untracked). Future local real runs with `--subsample` need it first on PATH.
5. **Local real runs use bsdtar**; hazel uses GNU tar 1.35 from the demux env. The fixture tar is plain ustar, readable by both.
6. **Shell-rule slips:**
   - one empty heredoc (`python3 - <<'EOF'`, no effect);
   - one multi-line `python3 -c` (it edited nextflow.config / nextflow_schema.json; the result was reviewed);
   - `cd … &&` chains in single-line commands.
   No removals.
7. **Scratch left for the user** (remove only with consent): `agent/20260928_171000_localrun/`, `agent/cachetest/20260928_161358/`,
   `.nf-test/` test dirs, `agent/check_resources/<time>` of this check run. Also the untracked `conf/containers_*.config` that
   `nf-core modules patch` regenerated (gitignored).
