# PLAN: cleanup after the container phase

Written 2026-09-30, on branch `containers`. Runs **after** docs/PLAN_containers.md step 5 (the switch) is done and merged
into `main`, between two waves. Nothing here is done yet.

## 1. Rules (every item below)

1. **List first, remove later.** One script per area in `agent/` (`YYYYMMDD_HHMMSS_list_<area>.sh`): for each candidate path
   `ls`, size (`du -sh`) and file count (`find | wc -l`), then a commented `# CONSENT: rm -r -- '<path>'` line. The user
   approves paths (or whole categories named in the listing); only then are those lines uncommented and run. No `rm` of a
   variable, no globs in removal lines, no `find -delete`, no `git clean`.
2. **No session still needs it.** Before a path is listed, check that no Claude session, worktree or running job uses it
   (`squeue`, `git worktree list`, the other sessions' handovers), and that its measurements are recorded in a doc
   (REQUIREMENTS, PLAN_*, run cards). Logs and small records (`*.sh`, `*.py`, `*.md`, `*.log`, `*.tsv`) are kept.
3. **Measure before and after.** Hazel: `mmlsquota -g maize gpfsHPCcommon2` (files, the binding limit) and the inode audit
   `agent/20260930_160000_count_inodes.sbatch`; laptop: `du -sh` and file counts of each `agent/`.
4. On hazel every listing and removal runs as a Slurm job (xfer partition), never on the login node.

## 2. Hazel (`/share/maize`, 1,000,000-file group quota)

Baseline 2026-09-30 after the stale-env removal: group **521,333 files**; frodrig4 ≈ 195,700 (audit job 999743).

| # | what | files (2026-09-30) | when / condition |
|---|---|---:|---|
| H1 | the 18 remaining conda prefixes `/share/maize/frodrig4/conda/zealgt/*`, except the Nextflow launcher (`nextflow-*`) | ≈ 106,000 | PLAN_containers step 5: containers are hazel's default and no branch's `conf/env_prefixes.config` needs them (`scripts/build_envs.sh --list-stale --all-refs`) |
| H2 | conda package cache `/share/maize/frodrig4/conda/pkgs` (after H1 only the launcher's packages are needed) | 88,934 | with H1; keep what the launcher env links (`find pkgs -type f -links +1`), or rebuild the launcher from its yml afterwards |
| H3 | `nf_work/<run>/` of finished runs: `work/`, `tmp/`, stub stores, checkpoints of test runs (`containers_g0`, `containers_g1`, `conda_g1`, the genotype container tests, older gate runs) | 56,982 (all nf_work) | after each run's comparison / measurements are written up; the pipeline's own `cleanup_<run>.sh` lists stage-2 dirs (usage.md "Waves of libraries") |
| H4 | Apptainer temp and layer cache `/share/maize/frodrig4/apptainer/{apptainer_tmp,apptainer_cachedir}` | 2 | after the last `apptainer pull` (images stay in `apptainer/cache/`) |
| H5 | SIFs no module references any more (after an image update) in `apptainer/cache/` | 1 file each | compare the cache with `nextflow inspect -profile hazel,apptainer_hazel` of `main` |
| H6 | hazel checkouts no longer needed: `ZEAL/zealgt-genotype` (branch merged), `ZEAL/zealgt-containers` (after the containers merge) | ~1,500 each | on `/rsstu`, not the /share quota; after checking no session submits from them (`ZG_REPO`) |
| H7 | old job logs in `/share/maize/frodrig4/nf_work/*.log`, `/share/maize/frodrig4/zg_*.log` | small | keep; move to one `logs/` dir only if wanted |

Expected after H1–H3: the conda tree drops from ≈ 136,000 to ≈ 8,000 files (the launcher); the whole image set stays ≈ 22
files.

## 3. Laptop (disk, not a quota)

Measured 2026-09-30 (`agent/20260930_170000_measure_agent_dirs.sh`):

| checkout | files | size | largest |
|---|---:|---:|---|
| `~/repos/zealgt/agent` | 39,989 | 17 GB | `20260929_194500_demux_test12m/` 12 GB, `20260929_193000_demux_test/` 3.3 GB, `.venv_nfcore/`, `.venv_cutadapt*/` |
| `~/repos/zealgt-containers/agent` | 95,294 | 6.4 GB | `cachetest/` 30 K files, `check_resources/` 27 K, ~20 `*_localrun/` |
| `~/repos/zealgt-genotype/agent` | 24,495 | 0.8 GB | `nft_*/`, `check_resources/` |

Categories:

- **L-keep, tooling:** `bin/` (nextflow, nf-test), `stubbin/` (version shims), `.venv_nfcore/`, and the cutadapt venvs if a
  script still uses them. One copy is enough: the checks point `ZG_CHECK_PATH` at `~/repos/zealgt/agent`; the other
  checkouts keep only their own `stubbin/` (the containers one is the current version).
- **L-keep, records:** scripts, logs, notes, tsv tables, handovers.
- **L1, run output (remove):** Nextflow work dirs of local runs and tests: `*_localrun*/`, `*_localrun_*`, `nft_*/`,
  `*_nftest/`, `*_gaterun/`, `cachetest/`, `check_resources/<timestamp>/` except the latest. Regenerable.
- **L2, demux test data** (`~/repos/zealgt/agent/*demux_test*`, 15 GB): the zealgt-fe session's CRAM Gate 2 bug work;
  only after that session (or its handover) says the evidence is no longer needed.
- **L3, docker:** images and build cache (`docker system df`; `docker image rm` of the `zealgt-*:dev` tags,
  `docker builder prune`), when no Dockerfile is being worked on.
- **L4, git:** prunable worktree `~/repos/zealgt/agent/cr_gate2_wt` (`git worktree prune`), `agent/wt_gate2_bug` (gate2-bug,
  with the zealgt-fe session), merged local and remote branches `simplify`, `genotype`, later `containers` (only with the
  user; remote branches are shared).

## 4. GitHub

- Container packages: keep `zealgt-crisp` and `zealgt-nilhmm` (public). `zealgt-tools` was deleted 2026-09-30 (restorable
  for 30 days). Old versions of a package are deleted only when no commit's `container` line uses them.
- Org setting "Package creation → Public" was turned on 2026-09-30 for the two packages; decide whether it stays on.

## 5. Prevention (so it does not pile up again)

- `scripts/run_checks.sh` / `scripts/check_resources.sh`: keep only the latest `agent/check_resources/<timestamp>/` (or
  write into one fixed scratch dir, replaced each run).
- nf-test: one fixed `NFT_WORKDIR` per checkout (`agent/nftest/`), reused, instead of a new dated dir per run.
- Each hazel test run's run card names its run dirs, and the write-up of the run ends with the cleanup listing for them.

## 6. Order

1. After the switch is merged: H1 + H2 (the big quota win), measured with the inode audit.
2. H3 / H4 for the container test runs, once their comparison is written in docs/PLAN_containers.md.
3. Laptop L1 in `zealgt-containers` (this session's own), then the other checkouts together with their sessions (L2, L4).
4. Prevention changes (§5) as a small code commit, checked like any other.
