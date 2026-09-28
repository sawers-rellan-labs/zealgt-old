You are writing the zealgt Nextflow pipeline from scratch, reviewing it with CodeRabbit, and debugging it on the hazel cluster
until it passes the testing ladder. Repository: /Users/fvrodriguez/repos/zealgt. Nothing of the pipeline exists yet (only docs/, meta/,
agent/); do not port or read old pipeline code from other repositories — the specification is the plan, and the only external code
you may consult is the algorithm scripts the plan names for stages 3–6 (zealbc1 PHG/bin/*.py, read for the maths, rewritten as modules).

Read first, in this order, and follow them: CLAUDE.md (agent/ scratch; any command longer than one line — loops, chains, heredocs,
inline R/Python, ssh payloads — goes into agent/<YYYYMMDD_HHMMSS>_<desc>.<ext> and is run from there; no recursive removal and no
deletion of any kind without the user's explicit consent for that target); .claude/skills/hazel-debug-loop/SKILL.md (git is the only
transfer to hazel; commit → push → `git pull` on hazel; every hazel action is one non-interactive ssh line or `ssh hazel 'bash -s' <
agent/<script>`; all compute through Slurm `--account=maize_cpu --partition=compute_partners --qos=short`, deep alignment on
compute/normal; never nextflow on the login node; module .nf edits only, never main.nf for a fix; `-resume <session-id>`; kill runs by
exact job id); docs/PLAN_pipeline.md (the specification: §0 tasks 1–2, §2 principles and hash hygiene, §3 stage table and stage 6,
§4 known issues and their decisions, §5 storage rules, §6 testing ladder); docs/REQUIREMENTS.md (inputs, environments, measured
resources); docs/math_supplement.tex (the models of stages 3–6); meta/samples.csv, meta/dev_import.csv and meta/*well_map* (sample
sheets); agent/handover_20260927_213500_review_check.md (fixes the pipeline must include, esp. finding #1: step 2 carries the step-4
flags and treats x = 0 line reads as zero-class reads; #7: step-4 tables keyed by module version / run in the store; #8: per-sample
count tasks batched).

What to build
- Two workflows in one repo, named by their endpoints: the CRAM workflow (raw libraries → analysis-ready CRAMs + QC + provenance +
  demux registry) and the genotype workflow (CRAM store + sample sheet + run card → discovery, union, ancestry, gap filling, genotypes,
  reporting). The store is the only contract between them. Entries exactly as the stage table (§3): read_demultiplexing, read_trimming,
  read_alignment, sample_quality_control, variant_discovery, ancestry_inference, marker_union, donor_allele_calling,
  genotype_imputation, reporting; plus reference_variant_space (§3, later). One module per step, no duplicated commands; every module
  has a `stub:` block.
- Principles §2 are hard requirements: storeDir for CRAMs / demux QC / step-4 tables (keyed as the review fix says); comments outside
  script blocks; threads and memory from Slurm env, not ${task.cpus}; `cache 'lenient'` on large inputs; temporaries die inside the task;
  workDir and TMPDIR on /share/maize/frodrig4/nf_work/<run>, results on /rsstu; environments referenced by prefix (conda.enabled per
  profile, off for stub); profiles stub / slurm / local.
- §0 is law: development entries start from CRAMs; read_demultiplexing refuses a registered library unless --force-demux <library>;
  one DEMUX+ALIGN task per library aligns all its samples, FASTQs only in task scratch; raw libraries are read-only; maxForks 4.
- CRAM stop point (§3): B73 v5, read groups in every read, duplicates flagged not removed (samtools markdup -d 2500), no MAPQ filter,
  QC (FastQC, samtools stats, markdup stats, Picard CollectWgsMetrics), provenance record, registry entry. MAPQ / BQ filters live in the
  genotype workflow (mpileup -q20 -Q20, CRISP --mmq 20).
- Genotype workflow stages 2b–8 as specified, including the decided items of §4 (BED clip after CRISP, mpileup -I, 0.05× exclusion,
  coverage QC 2 × rigidity, RTIGER as run before, two-step gap filling with the additive rule and the review fixes, raster genotypes,
  reporting against the BC2S2 expectation). Open decisions of §7 stay parameters in the run card, not code choices.
- Write docs/REQUIREMENTS.md resource rows from measurements as you go; keep docs/PLAN_pipeline.md untouched except for a status line
  the user asks for.

Resource allocation (conf/slurm.config; every process gets a label, every label a measured request; start from docs/REQUIREMENTS.md §4
and correct the numbers from `seff` / `sacct` after each gate — record them there)
- Conventions as run in zealbc1 nilhmm (its nextflow.config, gate scripts): resources in each module body, config maps labels to env
  prefixes only; `errorStrategy 'retry'`, `maxRetries 2` (3 attempts) with memory escalation on OOM (alignment 24 → 48 → 72 GB);
  `executor.queueSize` 80 on normal, 40 on short; a debug/short profile that caps every process at 1 h; `--account=maize_cpu` in
  `clusterOptions`; `maxForks 4` on DEMUX+ALIGN (scratch peak ≤ 1.5 TB, §5); trace.txt with peak_rss / realtime per task, read after each gate.
- The one design change from nilhmm: nilhmm aligned each sample as its own 1–4 h task; the plan's Task 2 demuxes and aligns all samples
  of a library in one task (12–24 h on normal). That task must be restart-safe: each sample's CRAM is written to the store as it
  finishes and a rerun skips samples whose CRAM (and index) already exist, so a failure at sample 11 costs one sample, not the library.
  Gate 2 measures one library this way before any other library is submitted.
- Partition / QOS per label: `short` (compute_partners, ≤ 2 h) for everything in the genotype workflow and for stub / gate runs; `normal`
  (compute) only for the CRAM workflow's deep-library tasks; `xfer` (`--partition=xfer --mem=8G`) for downloads only. The Nextflow head
  job itself is a small short-QOS job (1 cpu, 4 GB, 2 h for gates; longer on normal for Gate 2 of the CRAM workflow), never the login node.
- Starting requests (measured in REQUIREMENTS §4, jobs cited there):
  - DEMUX+ALIGN, one BC1 library (12 samples, 80–362 GB raw): 8 cpu, 24 GB escalating to 48 / 72 GB on retry (sort at ~20× needed
    ≥ 48 GB in 935092 / 945148), 24 h on normal; samples aligned sequentially inside the task, ~1 h per sample (12–13 min per 1× of
    depth), restart-safe as above; scratch ≈ 1.1 × library on /share.
  - DEMUX+ALIGN, one batch-2 row library (BC2S3 lines, ~18 lines): 8 cpu, 32 GB, 2 h short.
  - MARK_DUPLICATES-only pass on imported CRAMs: 2 cpu, 12 GB, 30 min short (array 963772: 6–16 min per BC1 sample).
  - QC per sample (FastQC, samtools stats, CollectWgsMetrics): 2 cpu, 8 GB, 1 h short; MultiQC per library: 1 cpu, 4 GB.
  - Per-sample / per-line counts (QC panel, union sites): batched, one task per donor × chromosome over all its samples: 2 cpu, 8 GB,
    1 h short (finding #8: never one task per sample × chromosome).
  - variant_discovery, one donor × chr10 (witness merge + CRISP + BED clip + veto + B73 counts + step 4): 8 cpu, 48 GB requested (CRISP
    measured 0.35 GB; the witness merge is the memory user), 2 h short; measured 8–17 min.
  - RTIGER, one donor × chromosome: 4 cpu, 16 GB, 2 h short (confirm; RTIGER is R, single-threaded per line).
  - marker_union, gap filling steps 1–2, raster, reporting: 1–2 cpu, 12–16 GB, 1 h short (step 2 measured 35 s / 0.9 GB on chr10).
  - reference_variant_space (AnchorWave, later): 8 cpu, 16 GB, 2 h short per chromosome; measure memory on one chromosome first.
- Environments: prebuilt once on the login node from pinned ymls in envs/ into the persistent prefix
  `/rsstu/users/r/rrellan/BZea/ZEAL/envs/<name>` (assembly, nilhmm, qc, nextflow; docs/PLAN_cleanup.md group 4 — `/share/maize/frodrig4/conda`
  is being retired and is not persistent). Every `withLabel` names a prefix; compute nodes have no internet, so no env is built at task time.
- Scale to keep in view (§5): ~130 BC1 samples and ~185 lines to align in Task 1 (~1,000 CPU-h), ~3,000 CPU-h for all BC1 samples;
  the group file quota on /share (~224 K files left) is the binding limit, so every gate reports file counts and stub work/ is cleaned
  with consent.

How to work
1. Plan the file layout (main.nf, workflows/, modules/, conf/, bin/, envs/*.yml, docs/runs/<run>.md) and write it locally. Commit in
   small explicit steps (`git add <paths>`, never -A); attribution lines per the session's rules.
2. Gate −1: before each push of a substantive change run `coderabbit review --committed --base main --agent` (or `--uncommitted`), read
   every finding against the code and the plan, fix what is real, record what you rejected and why in agent/. CodeRabbit finds code/API
   bugs, not environment/data bugs.
3. Gate 0: push, pull on hazel, run `-stub-run` as a tiny short-QOS job for every entry; the whole DAG must wire (channel joins,
   filenames, storeDir paths). Clean stub work/ only with the user's consent.
4. Gate 1: tiny real subset on short QOS, as zealbc1 ran it (`--subsample 1000000` read pairs of one library for the CRAM workflow; a
   few CRAMs from meta/dev_import.csv, one donor × a small region of chr10 for the genotype workflow). Data grows only gate by gate:
   stub → 1 M pairs / one region → one full library / one donor × chr10 → full, never skipping a rung. Inner loop of
   the skill: read .command.err / .out / .sh in the task dir, fix the module, commit, push, pull after the run has stopped, rerun with
   -resume <session-id>. Never edit on hazel, never rsync.
5. Gate 2 (one full unit: the two mexicana pilot donors × chr10 on short QOS; the CRAM workflow's one full library on compute/normal)
   only when Gate 1 passes and after telling the user the requested resources; record measurements in docs/REQUIREMENTS.md, file counts
   included (§5). Nothing full-scale (Gate 3) without the user's go.
6. Never submit anything that demultiplexes an already registered library, never delete work/, store or results, never run a heavy
   process on the login node. When a step needs a decision the plan leaves open, stop and ask; otherwise proceed.

Output at the end of your session: a handover agent/handover_<YYYYMMDD_HHMMSS>_pipeline_build.md with the file layout, the gate reached
per entry with job ids and session ids, the CodeRabbit findings applied / rejected, measured resources, every open question, and the
exact next command. Keep claims tied to file:line or to a job id.
