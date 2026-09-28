Queued work (user, 2026-09-29): run only after Gate 2 on library 3A has finished (its hashes must not change mid-run).
Repo /Users/fvrodriguez/repos/zealgt, branch main. Coordinator + subagents; each subagent writes a handover and returns a short report.

Evidence: agent/20260928_081500_hashtest_results.md (Nextflow 26.04.6, job 972453): resource values interpolated into the script
(`${task.cpus}`, `${task.memory}`) do NOT change the task hash; `task.*` inside an `ext.args` closure DOES; executable bin/ scripts
named as a plain word are hashed by content; non-executable bin/ scripts called by path are not hashed (stale-output trap).
agent/20260928_075824_nextflow_cache_practices.md (docs + source): storeDir is being deprecated (26.10 docs, PR #7574); the
recommended replacement is explicit "use the stored output if it exists" workflow logic; cache entries are tied to one process in one
session (discussion #5612); do not hide logic from the hash. Issue #3581 (wontfix, Nextflow 22.04) no longer reproduces on 26.04.6.

1. Drop the Slurm resource helper: remove bin/export_slurm_resources.sh and every `source export_slurm_resources.sh`; local modules use
   `${task.cpus}` / `${task.memory}` the standard nf-core way; revert the resource-only nf-core module patches (keep only functional
   patches, e.g. TRIMMOMATIC's no-trimlog patch, documented); JVM -Xmx from task.memory with a headroom as nf-core modules do.
   Add a check (lint step or nf-test) that no `task.*` appears inside an `ext.args` / `ext.args2` closure in conf/*.config.
   Keep the pipe exit-code propagation (OOM 137/140 → retry) inside the module scripts.
2. FASTQ checkpoint and two stages:
   - Stage 1 `read_demultiplexing`: DEMUX per lane → MERGE_LANES → TRIMMOMATIC → FASTQC, then publish each sample's trimmed pair with
     `publishDir mode: 'link'` (hardlink: same GPFS filesystem as work/, no extra space or inode) to
     /share/maize/frodrig4/fastq_checkpoint/<library>/, plus a per-library samplesheet.csv (sample, fastq_1, fastq_2, crops already
     applied, demux/trim provenance) validated by an nf-schema schema.
   - Stage 2 `read_alignment` (reinstated, input = checkpoint samplesheets only): ALIGN_MARKDUP → CRAM → QC; skip a sample whose CRAM +
     index already exist in the store (explicit workflow logic, the zgIsStored pattern) — replace storeDir for CRAMs / demux QC with this
     logic, keeping the "never overwrite a stored CRAM" guarantee.
   - The default `read_demultiplexing` run chains into stage 2 (one command per library). Stage 2 can be rerun alone after a fix.
   - Cleanup of a library's checkpoint FASTQs only after all its CRAMs are stored and verified, reported by the run, removed only
     with the user's consent.
3. PLAN: §2 hash table corrected with the hash-test evidence (resource interpolation not hashed on ≥ 26.04.6; ext.args closures and
   executable bin/ scripts are; non-executable interpreter-called bin/ scripts are not — keep output-affecting helpers in module
   templates/); §3 stage table (checkpoint, two stages); §5 (checkpoint footprint ≈ N libraries in flight × ~1× raw, hardlinked;
   cleanup rule); drop storeDir from the principles in favour of the explicit skip logic. REQUIREMENTS §4 unchanged except notes.
4. Gates: nfcore-compliance pre-push checklist (lint, schema lint, nextflow lint, nf-test incl. a cache test proving (a) a resource
   change keeps stage-1 and stage-2 tasks cached and (b) a stage-2 module edit does not rerun stage 1), CodeRabbit gate, push, then
   Gate 0 (stub) and Gate 1 (1A subsample through the same code path, multi-lane, full thread counts) on hazel. No Gate 2 rerun without
   the user's go.
Rules: CLAUDE.md, hazel-debug-loop and nfcore-compliance skills; single plain git/ssh commands; stage explicitly (never
docs/math_supplement.tex); no deletions beyond the replaced code (git rm) without consent; commits end with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; the genotype session works on branch `genotype` — pull --rebase before push.
