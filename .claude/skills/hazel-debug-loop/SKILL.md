---
name: hazel-debug-loop
description: Run and debug the zealgt Nextflow pipeline (read processing + genotyping) on the hazel HPC cluster from the laptop.
  Use whenever iterating on, submitting, or troubleshooting zealgt on the cluster — covers git-only transfer, the two filesystem
  facts (core.fileMode false + interpreter-invoked scripts), login-node policy (short QOS for all compute), job environment and
  node sizes, conda env builds, where work/ and the store live, the inner fix loop, testing-ladder lessons, and killing a run safely.
---

# Hazel debug loop (zealgt)

Adapted from zealbc1 `.claude/skills/hazel-debug-loop/`. How code is written on the laptop, moved to hazel, and iterated until a
pipeline step works. Stage names, profiles, storage rules and the testing ladder (gates, §6) come from `docs/PLAN_pipeline.md`;
inputs, envs and measured resources from `docs/REQUIREMENTS.md`. Module/config conventions: the `nfcore-compliance` skill.

## Paths
- `ZEAL` = `/rsstu/users/r/rrellan/BZea/ZEAL` (persistent). zealgt checkout on hazel: **`ZEAL/zealgt`** (next to zealbc1's
  `ZEAL/code` and `ZEAL/code-phg`; never edit those from here).
- Nextflow `workDir`: `/share/maize/frodrig4/nf_work/<run>` (2 TB, **not persistent**), never under `/rsstu`.
- Durable outputs: `storeDir` under `ZEAL/store/` (CRAMs, demux QC, step-4 tables, reference variants); published results under
  `ZEAL/results/`.
- Old nilhmm `ZEAL/results/work` (demuxed per-sample FASTQs) is **gone**: PLAN §0 Task 1 ("align from existing FASTQs") is void;
  every library demuxes again from raw.

## Branch model
- `main` only, as in zealbc1. Branch only for a risky change you might discard, and delete that branch when it is merged.
- Stage files **explicitly** (`git add <paths>`), never `git add -A` / `git commit -a`. Other agents may commit in the same repo.

## How code moves (laptop → hazel)
- Edits happen **locally**. `git commit` → `git push origin main` → `ssh hazel 'cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && git pull'`.
  Do **not** pull while a run is active (changed `bin/` scripts corrupt staged tasks); wait for the job to finish.
- **git is the only transfer** (byte-faithful, LF preserved). No rsync/scp/terminal paste, no hand edits on hazel.

## Two filesystem facts
- **`git config core.fileMode false`** on the hazel checkout (the `/rsstu` ACL strips the exec bit; otherwise every pull shows
  spurious mode-only "modified" scripts). Set once after cloning.
- **Invoke scripts through their interpreter with an explicit path** — `Rscript "${projectDir}/bin/x.R"`, `bash "${projectDir}/bin/x.sh"`,
  `python "${projectDir}/bin/x.py"` — never rely on `+x` + PATH. zealgt's task scripts avoid `${projectDir}` in the script text
  (it would enter every task hash): python helpers are module templates (`modules/local/*/templates/`), and the resource helper is
  sourced by name, `source export_slurm_resources.sh` (`bin/`) — bash `source` searches the task PATH (Nextflow adds `bin/`) and
  needs no exec bit. **Cache consequence (tested 2026-09-28, `nextflow-cache` skill):** a non-executable or interpreter-called `bin/`
  script is not part of any task hash, so editing it reruns nothing and keeps stale outputs — in the hazel checkout every `bin/` script
  is non-executable. Output-affecting helper code goes in module templates (hashed by content). Operator scripts live in `scripts/` (`submit_head_job.sbatch`, `build_envs.sbatch`, `build_envs.sh`, `run_checks.sh`).

## How commands run
- Each hazel action is one **non-interactive, one-line** `ssh hazel '<cmd>'`, self-contained (`cd`, `conda activate`). No state
  persists between calls. Avoid `set -u` in job wrappers (`source ~/.bashrc` trips on `$PS1`); keep parentheses out of remote `echo`s.
- **Permission allow rules match single plain commands only** (`.claude/settings.json`: `git push *`, `ssh hazel *`, `sbatch *`).
  Run `git -C <repo> push origin main`, `ssh hazel '…'`, `sbatch …` each as its own call — never chained with `cd`/`&&`/`;`/pipes.
- **Multi-line remote commands**: write them to `agent/<YYYYMMDD_HHMMSS>_<desc>.sh` (repo rule, `CLAUDE.md`) and run with
  `ssh hazel 'bash -s' < agent/<file>.sh` (or `ssh hazel 'sbatch' < agent/<file>.sbatch`) — stdin is byte-faithful, nothing is
  pasted. Anything that must outlive the session (sbatch wrappers, pipeline code) is tracked in the repo and reaches hazel by git.
- **Only trivial commands run over ssh directly**: `git pull`, `squeue`, `scancel <id>`, `cat`/`tail` logs, `seff`, `sacct`, `ls`, `du`.
- **Everything that computes goes through Slurm**: `--account=maize_cpu --partition=compute_partners --qos=short` (≤ 2 h; `short` is
  not allowed on the default `compute` partition). Full-library runs use compute/normal (`-profile hazel,normal`). Downloads and env
  builds use `--partition=xfer`. Never run nextflow or any heavy process on the login node — even a stub run is a tiny job.
- **Before any `rm`, `ls` the exact path** — `rm -f`/`rm -rf` on a wrong path fails silently. Removals still need user consent.

## Job environment (measured)
- The user's login env exports **`NXF_OFFLINE=true`** and **`NXF_ANSI_LOG=false`**; Slurm propagates both into every job. Any
  download/install step (e.g. `nextflow plugin install`) must `export NXF_OFFLINE=false` first.
- `<prefix>/bin/nextflow` fails with `java: command not found` unless `<prefix>/bin` is on PATH (or `JAVA_HOME=<prefix>`).
- Tasks see `SLURM_CPUS_PER_TASK` and `SLURM_MEM_PER_NODE` (MB, from `--mem`); `SLURM_MEM_PER_CPU` is unset. `nproc` is cgroup-limited.
- `module` is undefined in a non-login `sbatch --wrap` shell: use `bash -l -c '…'` or source the module init first.
- Quota: `/usr/lpp/mmfs/bin/mmlsquota -g maize gpfsHPCcommon2` (not on the default PATH). Watch the **file count** (1 M limit).

## Node sizes
- Smallest compute / compute_partners nodes: **20 cpu / 125000 MB** → `resourceLimits` 16 cpu / 120 GB so a task fits any node.
- xfer: 32 cpu / 188000 MB, no time limit (QOS `xfer` auto-set). Partition time limits show infinite; the QOS sets the real one.

## Conda envs
- Built by **`scripts/build_envs.sh` as an xfer job** (`sbatch scripts/build_envs.sbatch [<id>]`, submitted from the checkout so
  `SLURM_SUBMIT_DIR` is the repo) from each module's pinned `environment.yml` (+ `build.sh` for non-conda tools) into
  `/share/maize/frodrig4/conda/zealgt/<module>-<sha8>` (sha8 = content hash of environment.yml + build.sh).
- Never on `/rsstu` (too slow), never at task time (compute nodes are offline): `conf/env_prefixes.config` (generated,
  `--write-config`) points every process at its prefix; a `.nextflow.log` line "Creating env" means a missing entry.
- Editing an `environment.yml`/`build.sh` or renaming a `modules/local` dir changes the prefix: rebuild before running.
- A failed build leaves its prefix in place; removing it is the user's call.

## Inner fix loop when a task fails
1. `ssh hazel 'cat /share/maize/frodrig4/nf_work/<run>/<hash>/.command.err'` (also `.command.out`, `.command.log`, `.command.sh`).
2. Fix the **module `.nf`** (not `main.nf`, which rehashes every task).
3. Run the local checks, then **CodeRabbit on the exact commit** (user rule: before any real-data run and after every fix; findings
   fixed or rejected in writing in `agent/`). Stub runs may go first.
4. commit → push → `git pull` on hazel (after the run has stopped).
5. Re-run with **`-resume <session-id>`** (explicit id; a bare `-resume` can attach to an empty stub session).

## Testing-ladder lessons (gates: PLAN §6)
- **The small test run must exercise the same code path as the full run** — a subsample option must not switch to different I/O
  code. E.g. Gate 1's `--subsample` wrote real files, hiding the full-library FIFO path that failed at Gate 2.
- **Read the tool's documented input model before designing I/O.** E.g. cutadapt takes one input file per read and infers the
  format from the extension; `.gz`-named FIFOs failed with "File or stream is not seekable" → demux per lane, merge per sample with `cat`.
- **Propagate a killed stage's exit code** from pipes (OOM 137/140), or memory-escalation retries never fire. E.g. an OOM-killed
  `samtools sort` surfaced as markdup's exit 1 until `|| zg_pipe_fail "${PIPESTATUS[@]}"` was added.
- Tools can reject valid-but-filtered input: Picard needs `VALIDATION_STRINGENCY SILENT` on MAPQ-filtered imported CRAMs.
- Cache: resource-only changes keep the task hash (scripts read Slurm values, not `task.*`); `ext.args` changes rerun the task.
  Check with `-dump-hashes json` and `-resume <id>`.
- Record measured resources (trace, `sacct`/`seff`) in `docs/REQUIREMENTS.md` and extrapolate `work/` size and file count before
  scaling up.

## Killing a run safely (never a name glob)
With the slurm executor each process is its own Slurm job next to the head; `scancel <head>` alone orphans the children.
1. **Graceful:** `scancel --signal=INT --full <head>` — the signal reaches the nextflow process itself, which cancels its own
   children and exits ("Execution complete -- Goodbye"). Not `--batch`: that signals only the wrapper shell of
   `scripts/submit_head_job.sbatch`, which keeps waiting on nextflow while the head goes on submitting jobs (Gate 2, job 972212,
   2026-09-28). Check afterwards that the head job is gone and the log ends with the shutdown lines.
2. **Orphans:** cancel them by **exact job IDs** read from that run's `.nextflow.log` (`grep -oE "jobId: [0-9]+"`).
3. **Never `scancel` by name (`nf-*`)** — zealbc1 agents run Nextflow on the same account.

## Watching + safety
- Watch: `squeue -u frodrig4`, `.nextflow.log`, `sacct`/`seff` for measured resources (record them in `docs/REQUIREMENTS.md`).
- Every change is a git diff; never force-push; never rewrite `main` without the user.
- **No `rm`, recursive removal, overwrite, or `nextflow clean` on hazel without the user's explicit consent** for that specific target
  (`CLAUDE.md`). The only automatic writes are Nextflow's `work/`, the store, and published outputs.
- **No `rm` in generated commands at all**, except a removal the user approved for that exact path. Temporary files live in the job's
  own directory and are left for the user-approved cleanup; never "tidy up" with an `rm` of a variable (an unset or reassigned variable
  turns it into `rm -rf /dev/null`-style mistakes — seen 2026-09-28, refused by the permission rules).
- **Cleanup and any multi-line command only as a script in `agent/`**, never typed inline, so every removal is visible, reviewable and
  kept; print the exact paths (`ls`) before the removal line.
