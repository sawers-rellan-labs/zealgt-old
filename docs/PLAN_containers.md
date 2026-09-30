# PLAN: containers on hazel (Apptainer)

Branch `containers`. Simplified 2026-09-29 (user): the minimal nf-core route, nothing more. Starts after the genotype branch is
aligned with `main` and merged (merged 2026-09-30, PR #1). **Status 2026-09-30:** steps 1-3 done; step 4 done for the CRAM
workflow (§7), genotype workflow next (run card `docs/runs/containers_genotype_gate01.md`); step 5 not started. Cleanup
after the switch: docs/PLAN_cleanup.md.

## 1. Why

- **nf-core**: every module declares a container; zealgt has none ("No containers" deviation). Hazel can run them: Apptainer
  1.4.2 works on the compute nodes (§3 b), so the deviation's reason ("no container engine") was wrong.
- **Inode quota** (`/share/maize`, 1,000,000 files for the whole lab group; the file count is the binding limit): the conda tree
  is **174,148** inodes (job 993008; `pkgs` cache + 32 env prefixes, the largest multiqc at 55,683), the biggest single item of
  ours; a container image is **one file**. Pipeline runs are small (~900 files per library in `work/`).

## 2. What a module needs

| module kind | recipe | image | on hazel |
|---|---|---|---|
| 5 installed nf-core modules (cutadapt, fastqc, multiqc, picard, samtools stats) | theirs | already built, URLs in each `main.nf` | download the SIF |
| pure-conda local modules (CRAM workflow's 7 + the genotype ones) | `environment.yml`, versions only | **Seqera Containers** website: paste the packages, get a Docker URL and a SIF URL | download the SIF |
| `crisp` (CRISP) and the nilHMM module (`rtiger`) — not on conda | a **`Dockerfile` in the module directory** (nf-core rule: *"If the software is not available on Bioconda a `Dockerfile` MUST be provided within the module directory"*) | built by **GitHub Actions** into GitHub's container registry (public) | download once, Apptainer converts it to a SIF |

- A pure-conda module keeps `environment.yml` + its `conda` line and gets the nf-core `container` line (both URLs).
- The two Dockerfile modules get only a `container` line and refuse the conda profile, like the nf-core `cellranger` module.
- Images are never built on hazel (no root rights, compute nodes offline); hazel only downloads (xfer node) and runs them.

## 3. Tests already done (2026-09-29)

- **(a) Old conda envs** (job 993243): nothing removable yet — the 21 not used by `main` were all referenced by the genotype
  branch (older env naming). After the genotype merge, ~43 K inodes become removable (duplicate envs ≈ 34.6 K, unused `pkgs`
  files 8,263); removal only with the user's consent.
- **(b) Apptainer on a compute node** (jobs 993245, 993254): the SAMTOOLS_STATS SIF downloaded as one 108 MB file into
  `/share/maize/frodrig4/apptainer/cache`; `samtools 1.24` ran offline on c203n12; `TMPDIR` on `/share` worked; no files created
  anywhere. **Bind `/rsstu/users/r/rrellan/BZea`** (not `…/ZEAL`): `ZEAL/reference/B73.fa` links to `../../ref/`.

## 4. Decisions already made

- **nilHMM**: the pipeline uses tagged releases. **v0.3.1** (released 2026-09-30, PR #29) = the code of commit 248e67e (the
  benchmark's); only `DESCRIPTION`, `NEWS.md` and `_pkgdown.yml` differ. Pin: tag `v0.3.1` -> commit
  6e9b40833b7abe8065284f9c35f52cd7017c727d; archive
  `https://github.com/sawers-rellan-labs/nilhmm/archive/refs/tags/v0.3.1.tar.gz`, sha256
  `d9b5826afb9af7efd5e596e0d74bbf41c3194bad6f6da844ea48fea8d20ef7a0`. The Dockerfile installs from the tag. Later, once nilHMM is on CRAN: a conda-forge recipe;
  the module becomes pure conda and its Dockerfile goes.
- **CRISP**: installed from upstream `vibansal/crisp` (no fork), pinned by `git clone` + checkout of commit 1a9027e + a check
  that `git rev-parse HEAD` matches (not a downloaded archive, whose bytes GitHub may change).
- **No build-pinned conda**: `environment.yml` pins versions only (nf-core rule). A verbatim copy of an existing env keeps its
  content until the switch, so it shares that env; all build pins go at the switch (step 5), so tasks rerun only once.

## 5. Steps

1. **Settings file** `conf/apptainer_hazel.config`, profile `apptainer_hazel` (declared after `hazel` in `nextflow.config`):
   conda off, Apptainer on, `apptainer.cacheDir = '/share/maize/frodrig4/apptainer/cache'`,
   `apptainer.runOptions = '-B /share/maize/frodrig4,/rsstu/users/r/rrellan/BZea'`, the apptainer module on the head job's PATH.
   The Slurm settings do not change.
2. **Container lines** in the local modules: Seqera Containers URLs for the pure-conda ones (build strings dropped from their
   `environment.yml` at the same time); the two Dockerfiles + one GitHub Actions workflow (`.github/workflows/build_images.yml`)
   for `crisp` and the nilHMM module.
3. **Download** all images once with an xfer job (e.g. `nextflow inspect -concretize` if it fetches them; else a short list of
   downloads). Afterwards clear Apptainer's own cache once (conversion files), with consent.
4. **Test**: a stub run, then one small real run of each workflow (the Gate 1 fixtures) with `-profile hazel,apptainer_hazel`;
   compare the key outputs with the conda run (CRAM records, genotype tables).
5. **Switch**: containers become the hazel default, between two waves (every task hash changes, so never in the middle of one).
   Rewrite the "No containers" and "Build-pinned conda prefixes" deviations in their 4 places (`.nf-core.yml`,
   `docs/usage.md`, `docs/PLAN_pipeline.md` §2, nfcore-compliance skill). Then, with consent, remove the conda env prefixes and
   `pkgs` cache and check the quota (`mmlsquota -g maize gpfsHPCcommon2`).

## 6. Later, optional

- **GitHub Actions CI**: lint + nf-test with Docker on the test fixtures (the repository is public, so it is free). Removes the
  "No GitHub Actions CI" deviation. Possible only once step 2 exists.
- PROVENANCE records the image of each step (useful when the store holds CRAMs made with conda and with containers).

## 7. Results (2026-09-30)

**Steps 1-3.**
- Step 1: `conf/apptainer_hazel.config` + profile `apptainer_hazel` (6479cfe). The head job puts
  `/usr/local/apps/apptainer/1.4.2-1/bin` on PATH itself: the site module fails when `TMPDIR` is unset.
- Step 2: container lines in all 31 local modules. 29 pure-conda modules: Seqera Containers, requested frozen for
  linux/amd64 from their `environment.yml` (versions only), 10 distinct images (the python modules: one plain, one with
  gzip). CRISP and RTIGER: Dockerfiles in the module directories, built by `.github/workflows/build_images.yml` into
  `ghcr.io/sawers-rellan-labs/zealgt-crisp:1a9027e` (90 MB compressed) and `zealgt-nilhmm:0.3.1` (541 MB: conda-forge's
  r-base depends on the full compiler toolchain). One GHCR package per tool, tags = versions (a single `zealgt-tools`
  package was tried and reverted, 7d53ab4). New org packages start private and only an org owner can make them public;
  the user is now an owner and "Package creation → Public" is on.
- Step 3: 18 images on hazel in `/share/maize/frodrig4/apptainer/cache`: **22 files, ≈ 4.3 GB** (vs 174,148 inodes for
  the conda tree on 2026-09-29). Seqera SIFs downloaded as single files under Nextflow's names (xfer jobs 999636, 1000245);
  the two GHCR images pulled with `apptainer pull --disable-cache` (job 1000271).

**Findings.**
- **Hidden host tools.** Under conda a task also sees the host's tools; in a container only the image's. Seqera's SIF
  builds have a leaner base than its Docker builds (no gzip, zcat, xargs, find, tar; audit job 1000051), so local Docker
  nf-tests passed while hazel failed (`gzip: command not found` in DEMUX, stub job 1000024). Fix: `gzip=1.14` declared in
  the 10 modules that call it (0baa2ab), checked inside the new SIFs. Rule: every command a module calls is in its
  environment.yml; new images are checked inside the SIF on hazel.
- **Mount mode** (job 1000435): hazel's Apptainer is not setuid (`APPTAINER_SUID_INSTALL=0`, `allow setuid = no`); each
  SIF is mounted by a `squashfuse_ll` helper inside the task's job, 7-15 MB, plus 1-2 `starter` processes of 15-19 MB:
  ≈ 30-50 MB per task counted in its `--mem`.
- The stored CRAMs record the reference by its path in the task's `work/` dir (`@SQ UR:`); reading them needs
  `-T <B73.fa>` or `REF_PATH` (true on conda too).

**Step 4, CRAM workflow** (run card `docs/runs/containers_gate01_1a.md`; containers code a6868e3, conda `main` d3b6eb1):
- Gate 0 `containers_g0` (job 1000422): SUCCESS, 79 tasks, every one via `apptainer exec`, 0 "Creating env", 0 pulls.
- Gate 1 `containers_g1` (1000446, 25:51) vs `conda_g1` (1000447, 24:54), library 1A, `--subsample 1000000`; comparison
  job 1000663:

| check | result |
|---|---|
| task counts | identical, 79 tasks in 11 processes |
| CRAM alignment records, 12 samples (`samtools view -T`, md5) | identical |
| CRAM file size | containers 0.2 % smaller (compression of the image's htslib build; records identical) |
| Picard WGS metrics, markdup stats | identical apart from dates/comments |
| demux read pairs, demux log | identical apart from cutadapt's timing lines |
| tool versions (`zealgt_software_mqc_versions.yml`) | identical |

Peak RSS per process (trace `peak_rss`, max over tasks; containers / conda / request): ALIGN_MARKDUP 6,656 / 6,656 /
48 GB; PICARD_COLLECTWGSMETRICS 4,198 / 4,198 / 5 GB; SAMTOOLS_STATS 810 / 810 / 1 GB; MULTIQC 749 / 622 / 2 GB;
FASTQC 491 / 451 / 3 GB; DEMUX 350 / 414 / 2 GB; CUTADAPT 189 / 176 / 1 GB; the rest < 70 MB. No process near its limit.
The trace likely excludes the squashfuse helper; with it SAMTOOLS_STATS is ≈ 84 % of 1 GB at Gate 1 size, the one to
watch at Gate 2.
