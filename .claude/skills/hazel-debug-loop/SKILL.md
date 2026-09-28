---
name: hazel-debug-loop
description: Run and debug the zealgt Nextflow pipeline (read processing + genotyping) on the hazel HPC cluster from the laptop.
  Use whenever iterating on, submitting, or troubleshooting zealgt on the cluster — covers git-only transfer, the two filesystem
  facts (core.fileMode false + interpreter-invoked scripts), login-node policy (short QOS for all compute), where work/ and the
  store live, the inner fix loop, and killing a run safely.
---

# Hazel debug loop (zealgt)

Adapted from zealbc1 `.claude/skills/hazel-debug-loop/`. How code is written on the laptop, moved to hazel, and iterated until a
pipeline step works. Stage names, profiles and storage rules come from `docs/PLAN_pipeline.md`; inputs, envs and measured resources
from `docs/REQUIREMENTS.md`.

## Paths
- `ZEAL` = `/rsstu/users/r/rrellan/BZea/ZEAL` (persistent). zealgt checkout on hazel: **`ZEAL/zealgt`** (next to zealbc1's
  `ZEAL/code` and `ZEAL/code-phg`; never edit those from here).
- Nextflow `workDir`: `/share/maize/frodrig4/nf_work/<run>` (2 TB, **not persistent**), never under `/rsstu`.
- Durable outputs: `storeDir` under `ZEAL/store/` (CRAMs, demux QC, step-4 tables, reference variants); published results under
  `ZEAL/results/`.

## Branch model
- `main` only, as in zealbc1. Branch only for a risky change you might discard, and delete that branch when it is merged.
- Stage files **explicitly** (`git add <paths>`), never `git add -A` / `git commit -a`.

## How code moves (laptop → hazel)
- Edits happen **locally**. `git commit` → `git push origin main` → `ssh hazel 'cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && git pull'`.
  Do **not** pull while a run is active (changed `bin/` scripts corrupt staged tasks); wait for the job to finish.
- **git is the only transfer** (byte-faithful, LF preserved). No rsync/scp/terminal paste, no hand edits on hazel.

## Two filesystem facts
- **`git config core.fileMode false`** on the hazel checkout (the `/rsstu` ACL strips the exec bit; otherwise every pull shows
  spurious "modified" scripts). Set once after cloning.
- **Invoke scripts through their interpreter with an explicit path** — `Rscript "${projectDir}/bin/x.R"`, `bash "${projectDir}/bin/x.sh"`,
  `python "${projectDir}/bin/x.py"` — never rely on `+x` + PATH.

## How commands run
- Each hazel action is one **non-interactive, one-line** `ssh hazel '<cmd>'`, self-contained (`cd`, `conda activate`). No state
  persists between calls. Avoid `set -u` in job wrappers (`source ~/.bashrc` trips on `$PS1`); keep parentheses out of remote `echo`s.
- **Multi-line remote commands**: write them to `agent/<YYYYMMDD_HHMMSS>_<desc>.sh` (repo rule, `CLAUDE.md`) and run with
  `ssh hazel 'bash -s' < agent/<file>.sh` — stdin is byte-faithful, nothing is pasted. Anything that must outlive the session
  (sbatch wrappers, pipeline code) is tracked in the repo and reaches hazel by git instead.
- **Only trivial commands run over ssh directly**: `git pull`, `squeue`, `scancel <id>`, `cat`/`tail` logs, `seff`, `sacct`, `ls`, `du`.
- **Everything that computes goes through Slurm**: `--account=maize_cpu --partition=compute_partners --qos=short` (≤ 2 h; `short` is
  not allowed on the default `compute` partition). Workflow 1 alignment of deep libraries uses compute/normal. Downloads use
  `--partition=xfer --mem=8G`. Never run nextflow or any heavy process on the login node — even a stub run is a tiny job.
- **Conda envs are built by `bin/build_envs.sh` as an xfer job** from each module's pinned `environment.yml` (+ `build.sh` for
  non-conda tools) into `/share/maize/frodrig4/conda/zealgt/` — fast GPFS, rebuilt from the repo whenever /share is wiped; never on
  `/rsstu` (too slow to build on). Compute nodes have no internet, so Nextflow must never build an env at task time; every process
  points at its prebuilt prefix with `withName` in conf/hazel.config. `conda.enabled` per profile (on for slurm/local, off for stub).

## Inner fix loop when a task fails
1. `ssh hazel 'cat /share/maize/frodrig4/nf_work/<run>/<hash>/.command.err'` (also `.command.out`, `.command.log`, `.command.sh`).
2. Fix the **module `.nf`** (not `main.nf`, which rehashes every task).
3. commit → push → `git pull` on hazel (after the run has stopped).
4. Re-run with **`-resume <session-id>`** (explicit id; a bare `-resume` can attach to an empty stub session).

## Killing a run safely (never a name glob)
With the slurm executor each process is its own Slurm job next to the head; `scancel <head>` alone orphans the children.
1. **Graceful:** `scancel --signal=INT --batch <head>` — Nextflow cancels its own children.
2. **Orphans:** cancel them by **exact job IDs** read from that run's `.nextflow.log` (`grep -oE "jobId: [0-9]+"`).
3. **Never `scancel` by name (`nf-*`)** — zealbc1 agents run Nextflow on the same account.

## Watching + safety
- Watch: `squeue -u frodrig4`, `.nextflow.log`, `sacct`/`seff` for measured resources (record them in `docs/REQUIREMENTS.md`).
- Every change is a git diff; never force-push; never rewrite `main` without the user.
- **No `rm`, recursive removal, overwrite, or `nextflow clean` on hazel without the user's explicit consent** for that specific target
  (`CLAUDE.md`). The only automatic writes are Nextflow's `work/`, the store, and published outputs.
