You are building the zealgt CRAM workflow tonight, unattended, in /Users/fvrodriguez/repos/zealgt, and running it on the hazel
cluster until it passes Gate 1 and Gate 2 is running. Read, in this order, and follow: CLAUDE.md; .claude/skills/hazel-debug-loop/SKILL.md;
agent/prompt_20260927_next_agent_pipeline.md (the full build prompt: what to build, resource allocation, how to work, the gates);
docs/PLAN_pipeline.md §0, §2, §3 (CRAM workflow rows and stop point), §4 #1, #1b, #4, §5, §6; docs/REQUIREMENTS.md; meta/samples.csv,
meta/bc1_libraries.csv, meta/bc1_well_map.csv, meta/bc2s3_batch2_libraries.csv, meta/bc2s3_batch2_well_map.csv, meta/inline_barcodes.tsv,
meta/dev_import.csv.

Scope tonight: the CRAM workflow only — entries read_demultiplexing, read_trimming, read_alignment, plus the MARK_DUPLICATES-only import
pass for existing nilhmm CRAMs (§0 Task 2 bullet 4), the demux registry, the per-sample QC (FastQC, samtools stats, markdup stats, Picard
CollectWgsMetrics, MultiQC per library) and the provenance record. Build the genotype workflow's skeleton (main.nf entry dispatcher and
stub modules) only if it costs nothing; do not develop it.

Done by morning means, in this order:
0. The nf-core template scaffolded and committed untouched first (the build prompt's "Template" section); the DEMUX+ALIGN
   library task as one local module exactly as PLAN §0 (cutadapt → Trimmomatic → FastQC → minibwa | samtools → CRAM inside the task;
   env/assembly + zealgt_reads/bin on PATH, see the build prompt); nf-core modules only for the CRAM-level steps (samtools stats, the
   markdup-only import pass, picard/collectwgsmetrics, multiqc); registry and provenance as modules/local/ to nf-core conventions; `nf-core pipelines lint` and the stub nf-tests clean before the first push.
1. Code written locally, committed in small explicit steps (`git add <paths>`), CodeRabbit run on it (`coderabbit review --committed
   --base main --agent`), findings applied or rejected with a reason in agent/, pushed, pulled on hazel (ZEAL/zealgt).
2. Gate 0: `-stub-run` of every CRAM entry as a small short-QOS job; the DAG wires (channel joins, filenames, storeDir paths under
   ZEAL/store/{cram,demux_qc}, registry file).
3. Gate 1: real tools on 1 M read pairs of one BC1 library on short QOS (demux → trim → minibwa → read groups → fixmate → sort →
   markdup -d 2500 → CRAM without MAPQ filter → QC), and the markdup-only import pass on two dev_import CRAMs. Check the outputs: read
   groups in every read, duplicates flagged not removed, CRAM index, QC files, provenance record, registry entry. Then the cache
   check of the build prompt's step 4 (tests A, C, D with -dump-hashes on one patched module, isolated run directory); the resource
   interpolation inventory and bin/slurm_resources.sh exist before Gate 0.
4. Gate 2: one full BC1 library on compute/normal — library 1A (12 samples, 11 not yet aligned, FASTQs in results/work, launch
   results/pool_run_1A; the user may name another) — submitted and watched. Not Task 1, not any other library, before the user has seen
   Gate 2's measured numbers.
5. docs/REQUIREMENTS.md §4 updated with measured cpu / peak RSS / wall / disk / file counts per module from trace.txt and seff.
6. A handover agent/handover_<YYYYMMDD_HHMMSS>_cram_workflow.md: file layout, gate reached per entry with job ids and Nextflow session ids,
   CodeRabbit findings applied / rejected, measured resources, everything left open, the exact next command.

You are authorised (user, 2026-09-27) to write, run and debug the CRAM workflow without asking: commit, push, pull on hazel, submit
short-QOS jobs, fix and rerun, all within the hard limits below. Stub work/ was already cleaned by the user.

Run unattended: after every submission use /loop to wake yourself every 20–30 minutes, or at the job's expected length, and check
`squeue -u frodrig4`, `sacct -j <ids>`, the run's `.nextflow.log` and the failed task's `.command.err`; fix the module, commit, push,
pull on hazel only after the run has stopped, rerun with `-resume <session-id>`. Never sleep-loop in a shell, never keep an ssh session
open; every hazel action is one non-interactive ssh line or `ssh hazel 'bash -s' < agent/<script>`. Decide from the plan whatever it
settles; write what it leaves open into the handover instead of asking.

Hard limits: no deletion of any kind (no rm -r, no nextflow clean, no overwriting existing CRAMs or tables); no demultiplexing of a
library the registry or §0's table lists as demuxed unless the plan's --force-demux path is exercised deliberately at Gate 1 on the
subsample; conda environments are used as they are under /share/maize/frodrig4/conda/env/ (assembly, nilhmm, qc — picard for
CollectWgsMetrics, nextflow) plus ZEAL/envs/zealgt_reads (trimmomatic, fastqc) as mapped in the build prompt — verify each once with a
version call before Gate 0, rebuild nothing; nf-schema plugin fetched into NXF_PLUGINS_DIR on /share by an xfer job, head job
with NXF_OFFLINE=true; raw libraries are read-only; work/ and TMPDIR on /share/maize/frodrig4/nf_work/<run>,
results and store on /rsstu; all compute through Slurm (short QOS for gates, compute/normal for Gate 2's library), nothing heavy on the
login node; attribution lines on commits as the session's rules give them.
