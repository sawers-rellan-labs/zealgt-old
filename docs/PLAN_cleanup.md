# PLAN: cleanup after the container phase

Written 2026-09-30, on branch `containers`. Nothing here is done yet. Order of the project (user, 2026-09-30):

1. **Switch** to the container version of the workflow (docs/PLAN_containers.md step 5, merged into `main`).
2. **Cleanup 1**: the container-phase leftovers **and the conda envs** (except the Nextflow launcher). Everything the CRAM
   Gate 2 restart needs stays (§1a).
3. **CRAM Gate 2 debugging and restart**, on containers (zealgt-fe session, branch `gate2-bug`).
4. **Cleanup 2**: the Gate 2 material the restart no longer needs.

The conda envs are not kept for the Gate 2 debugging (user, 2026-09-30): the fix on `gate2-bug` (6c1e425) moves DEMUX's
compression from cutadapt's own writers to `pigz` behind FIFOs, so the part where a conda env and the image could differ
is no longer used; what needs testing is the new DEMUX on containers. After the switch every task hash changes, so the
paused runs cannot be resumed on either.

## 1a. Protected until the Gate 2 restart is done (not in cleanup 1)

- hazel `fastq_checkpoint/`: `2A/`, `2F/`, `3B/`: the trimmed reads of wave 1 (12 samples each, complete). The 13 CRAMs
  not yet stored (2A: S_2A_1, 2, 3, 4, 6, 8, 9; 2F: S_2F_2, 4, 5, 6, 8; 3B: S_3B_6) are made from them by
  `--entry read_alignment --libraries 2A,2F,3B` (stage 2 only, no demux; the 23 stored CRAMs are skipped).
- hazel `nf_work/`: the **logs and traces** of `cram_gate2_w01/`, `cram_gate2_b73/`, `gate2_3A/`, `gate2pre_fixture/`
  (the Gate 2 measurements). Their `work/` dirs can go in cleanup 1 once the zealgt-fe session confirms it does not need
  them (they cannot be resumed after the switch).
- the Nextflow launcher env `conda/zealgt/nextflow-*` and the `pkgs` files it links (it runs every head job), until it is
  replaced by the single-file launcher + pinned Java (docs/PLAN_containers.md §6, option B); then it and the rest of `pkgs` go.
- laptop `~/repos/zealgt/agent/` (demux test data, `*gate2*` scripts and reviews), the worktrees `agent/wt_gate2_bug`
  (branch `gate2-bug`) and `agent/cr_gate2_wt`, branch `gate2-bug`.
- never in any cleanup: `ZEAL/store/`, `ZEAL/results/`, the raw data.

Merge note for the restart: `gate2-bug` changes `modules/local/demux/main.nf`, which `containers` also changed (container
line; `gzip` in its environment.yml). Bringing the fix onto `main` after the switch needs a small manual merge of that
file; the fixed DEMUX calls `pigz`, which the DEMUX image has.

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
| H1 | the conda prefixes `/share/maize/frodrig4/conda/zealgt/*` except the Nextflow launcher (`nextflow-*`): 17 of 18 | ≈ 106,000 | **cleanup 1**: containers are hazel's default on `main` and no branch's `conf/env_prefixes.config` needs them (`scripts/build_envs.sh --list-stale --all-refs`; the `gate2-bug` branch still names them until it is rebased on the switch, so list them by hand) |
| H2 | conda package cache `/share/maize/frodrig4/conda/pkgs`, except the files the launcher env links | ≈ 80,000 of 88,934 | **cleanup 1**, with H1: remove the unlinked files (`find pkgs -type f -links 1`) and the package dirs of the removed envs, or rebuild the launcher from its yml afterwards and remove `pkgs` whole |
| H3 | `nf_work/<run>/` of finished runs: `work/`, `tmp/`, stub stores, checkpoints of test runs (`containers_g0`, `containers_g1`, `conda_g1`, the genotype container tests, older gate runs); the gate2 runs' `work/` only (§1a) | 56,982 (all nf_work) | cleanup 1, after each run's comparison / measurements are written up; the pipeline's own `cleanup_<run>.sh` lists stage-2 dirs (usage.md "Waves of libraries") |
| H4 | Apptainer temp and layer cache `/share/maize/frodrig4/apptainer/{apptainer_tmp,apptainer_cachedir}` | 2 | cleanup 1 (images stay in `apptainer/cache/`) |
| H5 | SIFs no module references any more (after an image update) in `apptainer/cache/` | 1 file each | compare the cache with `nextflow inspect -profile hazel,apptainer_hazel` of `main` |
| H6 | hazel checkouts no longer needed: `ZEAL/zealgt-genotype` (branch merged), `ZEAL/zealgt-containers` (after the containers merge) | ~1,500 each | on `/rsstu`, not the /share quota; after checking no session submits from them (`ZG_REPO`) |
| H7 | the wave-1 checkpoints `fastq_checkpoint/2A,2F,3B` and the gate2 runs' logs | 118 + small | **cleanup 2**, after the 13 CRAMs are stored and verified (the pipeline's `cleanup_status.tsv` per library) |
| H8 | old job logs in `/share/maize/frodrig4/nf_work/*.log`, `/share/maize/frodrig4/zg_*.log` | small | keep; move to one `logs/` dir only if wanted |

Expected after cleanup 1: the conda tree drops from ≈ 136,000 to ≈ 8,000 files (the launcher, with its `pkgs` files);
the whole image set stays ≈ 22 files; the group quota ≈ 330,000 of 1,000,000.

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
  cleanup 2, after that session (or its handover) says the evidence is no longer needed.
- **L3, docker:** images and build cache (`docker system df`; `docker image rm` of the `zealgt-*:dev` tags,
  `docker builder prune`), when no Dockerfile is being worked on.
- **L4, git:** merged local and remote branches `simplify`, `genotype`, later `containers` (cleanup 1, only with the user;
  remote branches are shared); the prunable worktree `~/repos/zealgt/agent/cr_gate2_wt`, `agent/wt_gate2_bug` and branch
  `gate2-bug` (cleanup 2, with the zealgt-fe session).

## 4. GitHub

- Container packages: keep `zealgt-crisp` and `zealgt-nilhmm` (public). `zealgt-tools` was deleted 2026-09-30 (restorable
  for 30 days). Old versions of a package are deleted only when no commit's `container` line uses them.
- Org setting "Package creation → Public" was turned on 2026-09-30 for the two packages; decide whether it stays on.

## 5. Prevention (so it does not pile up again)

- `scripts/run_checks.sh` / `scripts/check_resources.sh`: keep only the latest `agent/check_resources/<timestamp>/` (or
  write into one fixed scratch dir, replaced each run).
- nf-test: one fixed `NFT_WORKDIR` per checkout (`agent/nftest/`), reused, instead of a new dated dir per run.
- `scripts/check_resources.sh`, the slowest check (≈ 20 stub runs of the entries under `hazel,normal` and `hazel,short`,
  one after another; measured 2026-09-30 ≈ 25 of the suite's ≈ 30 min, each run over a minute although its stub tasks only
  `touch` files and the 16-cpu / 48 GB requests are only recorded, not used: the override's local executor claims 64 cpus
  and 1 TB).
  1. **First: fast polling.** `conf/hazel.config` sets `executor.pollInterval = '1 min'` (right for Slurm); the override
     switches to the local executor but keeps that interval, so every dependency step of a stub run waits up to a minute
     for tasks that finished in milliseconds. Add `pollInterval = '1 sec'` to the override's `executor` block (polling is
     not a resource request, so the check measures the same thing); time the check before and after (test the tool's
     behaviour first).
  2. **Only if still slow: parallel runs.** The runs are independent: every genotype entry has its own directory and a store
     freshly seeded from `tests/fixtures/genotype/store_seed`, and the two profiles are separate; only the two CRAM entries
     of a profile share a launch directory and store (give each its own). Run them as background jobs, 4-6 at a time (each
     is one Nextflow JVM, ≈ 1 core while starting, ≈ 0.5-1 GB); each writes its own trace rows, concatenated in a fixed
     order before the comparison with `tests/expected_resources.tsv`; a failed run still stops the check with its log.
  A small code commit of its own after the switch, checked like any other.
- Each hazel test run's run card names its run dirs, and the write-up of the run ends with the cleanup listing for them.
- **Fast gates: a `gate` profile + one head job per chain** (user, 2026-09-30). After the polling fix a Gate 0/1 chain is
  still mostly overhead (genotype Gate 1: critical path ≈ 3-4 min of work, longest task CRISP 76 s): every task is its own
  Slurm job, and the 7 entries are 7 head jobs, each queued after the previous one and each paying ≈ 40 s of Nextflow
  start-up. `conf/gate.config`, profile `gate` (after `hazel`): local executor inside one short-QOS allocation (e.g. 16
  cpus / 64 GB), `queueSize` ≈ 8, `resourceLimits` = the allocation; not the existing `local` profile (one task at a time,
  4 cpus, conda forced on: it is for debugging one task). A gate chain becomes one head job running the entries in
  sequence. Executor and resource settings are not in the task hash, so outputs and caching are unchanged;
  `scripts/check_resources.sh` keeps checking what the `hazel` profiles request. Gates only: Gate 2 and production keep one
  Slurm job per task. Expected genotype Gate 1 ≈ 8-10 min (from ≈ 15-20). Measure with the next Gate 0/1.
- **Nextflow start-up (≈ 40 s per head job)**, profiled 2026-09-30 (docs/REQUIREMENTS.md): (1) test a gate from a checkout
  on `/share` instead of `/rsstu` (script compilation ≈ 16-19 s); (2) validate `meta/samples.csv` only for `--workflow cram`
  (≈ 3.5 s per genotype head job; a small code change, with the switch).

## 6. Order

**Cleanup 1** (after the switch is merged, before the Gate 2 restart; nothing of §1a):
1. H1 + H2: the 17 conda prefixes and their `pkgs` files (the big quota win, ≈ 186,000 files), measured with the inode
   audit before and after.
2. H3 for the container test runs (`containers_g0`, `containers_g1`, `conda_g1`, the genotype container tests) and older
   non-Gate-2 runs, once their comparison is written in docs/PLAN_containers.md; the gate2 runs' `work/` dirs once the
   zealgt-fe session confirms; H4, H5.
3. H6: `ZEAL/zealgt-genotype` (merged); `ZEAL/zealgt-containers` after the containers merge.
4. Laptop L1 in `~/repos/zealgt-containers` and `~/repos/zealgt-genotype` (their sessions' own run output), L3 (docker),
   L4 for the merged branches.
5. Prevention changes (§5) as a small code commit, checked like any other.

**Cleanup 2** (after the Gate 2 restart, with the zealgt-fe session's handover):
1. H7: the wave-1 checkpoints `2A/2F/3B` (after their 13 CRAMs are stored and verified) and the gate2 runs' logs once their
   measurements are in the docs.
2. Laptop L2 (demux test data) and L4 for `gate2-bug` / `cr_gate2_whole`.
