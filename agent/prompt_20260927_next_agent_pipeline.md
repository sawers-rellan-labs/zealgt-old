You are building the zealgt Nextflow pipeline on the nf-core pipeline template, reviewing it with CodeRabbit and nf-core lint, and
debugging it on the hazel cluster until it passes the testing ladder. Repository: /Users/fvrodriguez/repos/zealgt. Nothing of the
pipeline exists yet (only docs/, meta/, agent/); do not port or read old pipeline code from other repositories — the specification is
the plan, the structure is the nf-core template, and the only external code you may consult is the algorithm scripts the plan names for
stages 3–6 (zealbc1 PHG/bin/*.py, read for the maths, rewritten as modules).

Template (not optional; no hand-rolled layout)
- Scaffold with nf-core/tools (`nf-core pipelines create`, non-interactive via `--template-yaml agent/<ts>_nfcore_template.yml`) into the
  repo root, pipeline name zealgt. Install nf-core/tools locally in its own laptop conda env; never on hazel. Keep: nf-schema
  (nextflow_schema.json + samplesheet schema in assets/), nf-test, MultiQC, conf/base.config + conf/modules.config, the `test` profile,
  modules.json. Drop: igenomes, nf-core institutional configs (compute nodes are offline), email / Slack / Teams, GitHub CI, the
  gitpod/codespaces files. Commit the untouched scaffold as its own first commit so every later change is a readable diff against it.
- Reproducibility is the requirement (user, 2026-09-27): everything needed to rebuild a run is in the repo — code, pinned
  environments, config, run card. One process per tool (PLAN §0 Task 2 and §2 rule 6 as updated 2026-09-27):
  DEMUX (cutadapt, one task per library) → TRIMMOMATIC (per sample) → FASTQC (per sample, trimmed reads) → ALIGN_MARKDUP (per sample,
  one process: minibwa -x sr → read groups → samtools fixmate -m → sort → markdup -d 2500 → CRAM, storeDir) → SAMTOOLS_STATS →
  PICARD_COLLECTWGSMETRICS → MULTIQC (per library). FASTQs pass through work/; one library in flight (`maxForks 1` on DEMUX, PLAN §5
  rule 3). Per-sample tasks make the library restart-safe by construction (storeDir skips stored CRAMs).
- Trimmomatic parameters: Nirwan's batch-1 run (PLAN §3 row 1b: ILLUMINACLIP 2:30:10, LEADING:3, TRAILING:3, SLIDINGWINDOW:4:15,
  MINLEN:36). The adapter FASTA is not written in the plan: find the one Nirwan's run used in the batch-1 scripts / logs next to
  `sara/BZea/filtered_S/` (read-only, one bounded `find -maxdepth 3`); if it is not found, use TruSeq3-PE-2.fa shipped with the
  pinned trimmomatic and flag it in the handover.
- nf-core modules (`nf-core modules install`) wherever one exists: trimmomatic, fastqc, samtools/stats, samtools (collate, fixmate, sort,
  markdup, index) for the markdup-only import pass, picard/collectwgsmetrics, multiqc, later bcftools/mpileup. DEMUX (cutadapt inline
  exact demux, not what nf-core cutadapt does) and ALIGN_MARKDUP (minibwa has no nf-core module) are local modules; so are registry,
  provenance, CRISP, RTIGER, stages 3–6. All of them go in
  modules/local/ written to nf-core module conventions: `meta` map in / out, `versions.yml` emitted, `task.ext.args` for flags,
  `stub:` block, an nf-test with a stub test. Subworkflows likewise (nf-core subworkflows where they fit, else subworkflows/local/).
- Two workflows in the template: workflows/cram.nf and workflows/genotype.nf, chosen by one `--workflow cram|genotype` param validated in
  the schema, dispatched from main.nf (main.nf edited only while scaffolding). The run card is a `-params-file`; every §7 open decision
  is a schema param.
- Where the template collides with PLAN §2 (hash hygiene). Why it matters: the task hash includes the evaluated script, so a task
  that succeeded on attempt 3 at 72 GB is rebuilt as attempt 1 at 24 GB on the next -resume, its script text differs, and the cache
  misses. storeDir outputs (CRAMs, demux QC, step-4 tables) are unaffected (storeDir checks files, not the hash), so the exposure is the
  non-storeDir tasks. Keep the fix small:
  - Inventory first: after installing each nf-core module, grep its main.nf script for `task.cpus`, `task.memory`, `task.attempt` (also
    inside `ext.args` closures in conf/modules.config) and list module / line / purpose (thread arg, memory arg such as Picard `-Xmx`
    or FastQC `--memory`, logic, logging) in agent/<ts>_resource_interpolation_inventory.md. Patch only modules that have one.
  - One helper, bin/slurm_resources.sh, sourced at the top of every patched and local script: exports ZG_CPUS from
    `SLURM_CPUS_PER_TASK` and ZG_MEM_MB from `SLURM_MEM_PER_NODE` (MB; Nextflow's slurm executor submits `--mem`; confirm once on
    hazel that `executor.perCpuMemAllocation` is off and the variable is set, else derive from `SLURM_MEM_PER_CPU` × cpus); validates
    both are positive integers; echoes `zg_resources cpus=… mem_mb=…` to stderr (lands in .command.log/.err, not in the script text);
    exits non-zero with a clear message if neither Slurm nor an explicit `ZG_CPUS`/`ZG_MEM_MB` override (local profile only, set in
    conf/local.config env scope) supplies them. No silent default. JVM tools get `-Xmx` as ZG_MEM_MB minus a fixed headroom inside
    the helper, never from task.memory.
  - Patch with `nf-core modules patch <module>` (patch in modules.json, upstream interface / outputs / labels unchanged, the patch touches
    only the resource values and says why in a comment above the script block). A module that cannot be patched without changing what
    it computes stays unpatched and is listed in the handover.
  - Not covered by this fix, on purpose: a changed environment.yml, ext.args or input still changes the hash (as it should); whether an
    edit to bin/slurm_resources.sh does is version-dependent — read it off the -dump-hashes output, do not assume;
    no containers are used, so env propagation is not an issue on hazel.
  Local modules follow §2 directly through the same helper. Resources follow the template: process_* labels in
  conf/base.config, per-module `withName` overrides in conf/modules.config (and conf/slurm.config for hazel), `ext.args` there too.
- Environments, the reproducible way (nf-core convention, not hand-made prefixes; user, 2026-09-28):
  - Every module keeps `conda "${moduleDir}/environment.yml"`. nf-core modules use the environment.yml they ship with (pinned, no
    edits). Each local module gets its own environment.yml pinning only the tools its script calls, exact version + build: DEMUX →
    cutadapt 4.9; ALIGN_MARKDUP → minibwa 0.7 (bioconda h118bc1c_0) + samtools 1.21 (two tools piped in one script, as nf-core's
    bwamem2/mem pins bwa-mem2 + samtools); registry / provenance → python. The versions are those zealbc1 ran, recorded in
    envs/legacy_zealbc1/ (snapshot of the old envs; the old /share envs are being deleted by the user — do not rely on them).
    Channels conda-forge + bioconda, strict priority. No env bundles unrelated tools.
  - Tools that are not conda packages get a pinned source build in the same env: next to the module's environment.yml a
    `build.sh` that downloads the source at a fixed commit (never a branch), verifies the commit, compiles with the compilers /
    libraries pinned in that environment.yml (conda-forge `c-compiler`, `make`, `zlib`, htslib as needed) and installs into
    `$CONDA_PREFIX/bin` (or the env's R library). Known cases (envs/legacy_zealbc1/README.md): CRISP = github.com/vibansal/crisp @
    1a9027ed16e6db6cf619d609806156cfc2e190fa (`make`, unpatched); nilHMM 0.3.0 = github.com/sawers-rellan-labs/nilhmm @
    248e67ead3693ae5af79d3cadd769e2d10b895f9 (`R CMD INSTALL` into an r-base 4.4.3 env). Before writing any module, list every tool
    it calls and check it on bioconda / conda-forge (`conda search`); any tool not found gets a build.sh the same way and is listed in
    the handover.
  - Location: `/share/maize/frodrig4/conda/zealgt/<module>-<first 8 of the yml+build.sh sha256>`, package cache
    `CONDA_PKGS_DIRS=/share/maize/frodrig4/conda/pkgs`. Never on /rsstu (NFS, far too slow for env builds; user 2026-09-28). /share is
    not persistent, which is fine: every env is rebuilt from the repo by one command.
  - Build: bin/build_envs.sh (tracked in the repo) as one xfer-partition job (compute nodes are offline): for each module env dir,
    `conda env create -p <prefix> -f environment.yml`, then its build.sh if present, then a smoke test (`<tool> --version`); skips a
    prefix that already exists with the same sha; writes envs/manifest.tsv (module, prefix, sha, source commits, tool versions, file
    count). conf/hazel.config points each process with `withName` at its prefix (so no env is ever created at task time); a
    `.nextflow.log` without "Creating env" in the first real run confirms it. The Nextflow launcher is built the same way from
    envs/nextflow/environment.yml (nextflow 26.04.6, as zealbc1 ran).
  - Not used: the old /share/maize/frodrig4/conda/env/* (being deleted by the user).
  - Containers: check once with a 1-minute short-QOS job whether `apptainer` or `singularity` exists on compute nodes (a .sif sits in
    ZEAL/envs/containers). Report it in the handover as the next step up; do not switch tonight.
- Offline compute nodes: the template's plugins (nf-schema) must be fetched once into NXF_PLUGINS_DIR on /share through an `xfer`
  partition job; the head job runs with NXF_OFFLINE=true.

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
  script blocks; threads and memory from Slurm env, not ${task.cpus}; `cache 'lenient'` on large inputs; temporaries die inside the task
  except the FASTQs between DEMUX, TRIMMOMATIC and ALIGN_MARKDUP; workDir and TMPDIR on /share/maize/frodrig4/nf_work/<run>, results
  on /rsstu; environments from each module's environment.yml (conda.enabled per profile, off for stub); profiles stub / slurm / local.
- §0 is law: development entries start from CRAMs; read_demultiplexing refuses a registered library unless --force-demux <library>;
  one DEMUX per library, then all its samples go through TRIMMOMATIC → FASTQC → ALIGN_MARKDUP; raw libraries are read-only; one
  library in flight.
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
- Behaviour as measured in zealbc1 nilhmm, expressed in the template's config files (not nilhmm's layout): `errorStrategy 'retry'`, `maxRetries 2` (3 attempts) with memory escalation on OOM (alignment 24 → 48 → 72 GB);
  `executor.queueSize` 80 on normal, 40 on short; a debug/short profile that caps every process at 1 h; `--account=maize_cpu` in
  `clusterOptions`; `maxForks 1` on DEMUX (one library in flight, peak ≈ 2 × library, §5 rule 3); trace.txt with peak_rss /
  realtime per task, read after each gate.
- As in nilhmm, each sample aligns as its own task (1–4 h on normal for deep BC1 samples); the library is demuxed once. Gate 2
  measures one library this way, including the work/ peak and file count, before any other library is submitted.
- Partition / QOS per label: `short` (compute_partners, ≤ 2 h) for everything in the genotype workflow and for stub / gate runs; `normal`
  (compute) only for the CRAM workflow's deep-library tasks; `xfer` (`--partition=xfer --mem=8G`) for downloads only. The Nextflow head
  job itself is a small short-QOS job (1 cpu, 4 GB, 2 h for gates; longer on normal for Gate 2 of the CRAM workflow), never the login node.
- Starting requests (measured in REQUIREMENTS §4, jobs cited there):
  - DEMUX, one BC1 library (80–362 GB raw): 8 cpu, 16 GB, 53–72 min per 94–140 GB pool (935092, 945148) → normal, 4 h.
  - TRIMMOMATIC per BC1 sample: 8 cpu, 8 GB, normal 2 h (measure at Gate 1; Java, -Xmx from the helper). FASTQC per sample: 2 cpu, 4 GB.
  - ALIGN_MARKDUP per BC1 sample (5–25×): 8 cpu, 24 GB escalating to 48 / 72 GB on retry (sort at ~20× needed ≥ 48 GB in 935092 /
    945148), 4 h on normal (12–13 min per 1× of depth).
  - Batch-2 row library (BC2S3 lines, ~18 lines, 0.4–1.2×): DEMUX 8 cpu 16 GB, ALIGN_MARKDUP per line 8 cpu 32 GB, all short QOS.
  - MARK_DUPLICATES-only pass on imported CRAMs: 2 cpu, 12 GB, 30 min short (array 963772: 6–16 min per BC1 sample).
  - QC per sample (FastQC, samtools stats, CollectWgsMetrics): 2 cpu, 8 GB, 1 h short; MultiQC per library: 1 cpu, 4 GB.
  - Per-sample / per-line counts (QC panel, union sites): batched, one task per donor × chromosome over all its samples: 2 cpu, 8 GB,
    1 h short (finding #8: never one task per sample × chromosome).
  - variant_discovery, one donor × chr10 (witness merge + CRISP + BED clip + veto + B73 counts + step 4): 8 cpu, 48 GB requested (CRISP
    measured 0.35 GB; the witness merge is the memory user), 2 h short; measured 8–17 min.
  - RTIGER, one donor × chromosome: 4 cpu, 16 GB, 2 h short (confirm; RTIGER is R, single-threaded per line).
  - marker_union, gap filling steps 1–2, raster, reporting: 1–2 cpu, 12–16 GB, 1 h short (step 2 measured 35 s / 0.9 GB on chr10).
  - reference_variant_space (AnchorWave, later): 8 cpu, 16 GB, 2 h short per chromosome; measure memory on one chromosome first.
- Environments: see "Environments, the reproducible way" above; bin/build_envs.sh runs (xfer job) before Gate 0, the launcher env first.
- Scale to keep in view (§5): ~130 BC1 samples and ~185 lines to align in Task 1 (~1,000 CPU-h), ~3,000 CPU-h for all BC1 samples;
  the group file quota on /share (~224 K files left) is the binding limit, so every gate reports file counts. The user cleaned the
  earlier stub work/ already (2026-09-27).

How to work
1. Scaffold the nf-core template (above), commit it untouched, then install / write modules one step at a time. The layout is the
   template's (main.nf, workflows/, subworkflows/{nf-core,local}/, modules/{nf-core,local}/, conf/, assets/, bin/, tests/,
   nextflow_schema.json, modules.json) plus docs/runs/<run>.md. Commit in small explicit steps (`git add <paths>`, never -A);
   attribution lines per the session's rules.
2. Gate −1: before each push, locally: `nf-core pipelines lint` (fix or justify every failure in .nf-core.yml), `nf-core pipelines
   schema lint`, `nf-test test --tag stub` for the touched modules; then run `coderabbit review --committed --base main --agent` (or `--uncommitted`), read
   every finding against the code and the plan, fix what is real, record what you rejected and why in agent/. CodeRabbit finds code/API
   bugs, not environment/data bugs.
3. Gate 0: push, pull on hazel, run `-stub-run` as a tiny short-QOS job for every entry; the whole DAG must wire (channel joins,
   filenames, storeDir paths). Clean stub work/ only with the user's consent.
4. Gate 1: tiny real subset on short QOS, as zealbc1 ran it (`--subsample 1000000` read pairs of one library for the CRAM workflow; a
   few CRAMs from meta/dev_import.csv, one donor × a small region of chr10 for the genotype workflow). Data grows only gate by gate:
   stub → 1 M pairs / one region → one full library / one donor × chr10 → full, never skipping a rung. Inner loop of
   the skill: read .command.err / .out / .sh in the task dir, fix the module, commit, push, pull after the run has stopped, rerun with
   -resume <session-id>. Never edit on hazel, never rsync.
   Cache check, once, on one patched module (Picard CollectWgsMetrics or FastQC) at Gate 1, in its own run directory so no real work/
   or store is touched: (A) run, then `-resume <id>` with that module's memory doubled in config → must be cached; (C) `-resume <id>`
   with one real parameter changed in ext.args and resources as in the first run → must rerun; (D) the `zg_resources` line in each
   .command.err matches the sacct allocation. Evidence: `-dump-hashes json` for both runs, the diffing hash component named, the
   "Cached process" lines, output md5s. Record it in the handover; do not claim a pass from unchanged script text alone.
5. Gate 2 (one full unit: the two mexicana pilot donors × chr10 on short QOS; the CRAM workflow's one full library on compute/normal)
   only when Gate 1 passes and after telling the user the requested resources; record measurements in docs/REQUIREMENTS.md, file counts
   included (§5). Nothing full-scale (Gate 3) without the user's go.
6. Never submit anything that demultiplexes an already registered library, never delete work/, store or results, never run a heavy
   process on the login node. When a step needs a decision the plan leaves open, stop and ask; otherwise proceed.

Output at the end of your session: a handover agent/handover_<YYYYMMDD_HHMMSS>_pipeline_build.md with the file layout, the gate reached
per entry with job ids and session ids, the CodeRabbit findings applied / rejected, measured resources, every open question, and the
exact next command. Keep claims tied to file:line or to a job id.
