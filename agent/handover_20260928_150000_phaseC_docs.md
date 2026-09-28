# Handover: Phase C docs (PLAN / REQUIREMENTS / CHANGELOG), branch `simplify`, 2026-09-28 15:00

Brief: `agent/20260928_090500_design_simplify.md` "Phase C" + coordinator task (PLAN §2/§3/§5/§6, REQUIREMENTS §4 notes, CHANGELOG).
Written while Phase B was still being implemented: checkpoint / two-stage text follows the brief, not the code. Not pushed.

## Commit
- `f7e7465` docs/PLAN_pipeline.md, docs/REQUIREMENTS.md, CHANGELOG.md (only these paths; committed with `git commit <paths>`).

## What changed
- PLAN §0 Task 2: FASTQs pass through work/, trimmed pairs hardlinked into the checkpoint until CRAMs stored + verified.
- PLAN §2: intro corrected (hash = source before substitution); hash table rewritten from job 972453 (task.cpus/memory in script
  not hashed ≥ 23.10; ext.args closure hashed by value; params by value; executable bin/ plain-word hashed; non-executable /
  by-path bin/ NOT hashed = stale; templates hashed; cache per process per session #5612; storeDir deprecated 26.10 PR #7574).
  Principles 2 (entries + published checkpoint), 3 (store by publishDir copy/overwrite:false/failOnError + zgIsStored skip; CRAM
  verified = CRAM + crai + CRAM 3 EOF; unverified → error naming the file), 4 (nf-core resources, helper removed, check_ext_args.py,
  templates/ for helpers, cache tested), 5 (checkpoint exception).
- PLAN §3: paragraph "Two CRAM-workflow stages and the FASTQ checkpoint"; rows 1 / 1b / 2 rewritten (FASTQC moved out of row 2;
  PROVENANCE → REGISTRY added to row 2; cleanup report).
- PLAN §5 rules 2 (store by publishDir + skip logic, versions.yml next to CRAM), 3 (checkpoint footprint ≈ N × ~1× raw,
  hardlinked, no extra space/inode while work/ holds the file; same-GPFS requirement; stage-1 task dirs cleanable once the
  samplesheet exists), 4 (cleanup rule + cleanup_status.tsv, consent).
- PLAN §6: "Lessons turned into checks" (check_resources.sh after the TRIMMOMATIC 12 h precedence loss; cache test).
- REQUIREMENTS §4: "Notes from Gate 2" (ALIGN_MARKDUP OOM analysis + new formula, MARKDUP_IMPORT share, TRIMMOMATIC 25–31 k pairs/s
  → 4 h, directives-only resources, checkpoint footprint). Tables unchanged.
- CHANGELOG: Added / Changed / Fixed bullets.
- No mention of `bin/export_slurm_resources.sh` left; PLAN §2 principle 4 records the helper's removal (history, no file name).

## Spots to reconcile after Phase B lands (described at brief level)
1. PLAN §3 paragraph + CHANGELOG: `params.fastq_checkpoint` name/default `/share/maize/frodrig4/fastq_checkpoint`, `--libraries A,B`
   for `read_alignment`, the `subsample_<N>` / `checkpoint_stub` guards.
2. PLAN §3: samplesheet column list is summarised ("sample, read group, source metadata, demux/trim settings, stage-1 run and code
   version"); the schema file name (`assets/schema_checkpoint.json`) is not named. Check against the implemented schema.
3. PLAN §3 row 2 / §5 rule 2: CRAM "verified" = CRAM + .crai + CRAM 3 EOF; unverified → error. Check Phase B implemented it this way.
4. PLAN §5 rule 4: cleanup_status.tsv columns and the log line wording ("removable (N files, X GB) …" / "keep: k of n CRAMs missing").
5. PLAN §5 rule 2: which store outputs moved from storeDir (CRAM, DEMUX_QC, PROVENANCE, REGISTRY, MARKDUP_IMPORT); "step4" tables
   listed as store outputs — genotype workflow, not checked here.
6. PLAN §6 cache test: `scripts/test_cache.sh` is Phase D (not yet built); described per the brief (R2 resources, R3 ALIGN_MARKDUP
   edit with fresh store, R4 read_alignment alone).
7. PLAN §5 rule 3 "stage-1 task dirs can be cleaned once its checkpoint samplesheet exists" is my inference from the design (stage 2
   reads the checkpoint); confirm it holds for the chained run.

## Open points (not in scope, not edited)
- PLAN §5 rule 6 says conda environments "move off /share to /rsstu"; contradicts §2 principle 6 and the user's rule (envs stay on
  /share, never /rsstu). Needs the user/coordinator to correct.
- PLAN §5 "CRAM-workflow disk budget" (2026-09-27 estimate, "1.1 × library per DEMUX+ALIGN task") predates the per-process split and
  the checkpoint; left as a dated estimate.
- REQUIREMENTS §4 Gate 2 notes: the job ids of the 3A OOM attempts are not cited (source used: main `agent/20260929_032000_align_rss.tsv`
  and commit 0a61f9c). The "retries at 48 / 72 GB also OOMed" statement comes from the coordinator brief.
- docs/usage.md / docs/output.md / README / skills' "This repository" sections belong to other writers (brief Phase C lists them).
- No checks run (docs only; nf-core lint does not read these files beyond CHANGELOG presence).
