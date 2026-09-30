# PLAN: Apptainer containers on hazel (inode quota + nf-core software requirements)

Branch `containers` (off `main` 1760b4f, 2026-09-29; starts after the genotype branch is aligned and merged into main). Status: **assessment done; (a) and (b) done (§6: nothing prunable yet, SIF test passed); nothing
else implemented.** Merged into `main` only after the containerised path passes the gates of §5; until then `main` keeps the conda
prefixes unchanged. Related: `docs/PLAN_pipeline.md` §2 (deviations), §5 (storage), §6 (gates); `nextflow-cache`,
`nfcore-compliance` and `hazel-debug-loop` skills.

## 1. Question

The `/share/maize` group quota is 1,000,000 files (GPFS `gpfsHPCcommon2`, fileset Share01, group `maize`, shared by the lab); the
file count, not space, is the binding limit (PLAN §5). Does moving from prebuilt conda prefixes to Apptainer SIF images (a) free
enough inodes and (b) bring the pipeline to the nf-core software requirements, without touching the Slurm configuration, the
scientific computations, or finished work?

## 2. Baseline (measured 2026-09-29, job 993008, `agent/20260929_220000_count_inodes.sbatch`)

Unique inodes (`find -printf '%i' | sort -u`: a hardlink counted once, as the quota counts), not directory entries, not `du`.

| location | unique inodes | entries |
|---|---|---|
| group quota (`mmlsquota -g maize gpfsHPCcommon2`) | **584,376 / 1,000,000** (775,811 on 09-27) | |
| `/share/maize/frodrig4/conda` (pkgs + 32 prefixes) | **174,148** | 429,384 |
| &nbsp;&nbsp;`conda/pkgs` (273 tarballs, rest extracted packages) | 88,934 | 88,934 |
| &nbsp;&nbsp;`conda/zealgt` (32 prefixes, hardlinked into pkgs) | 153,625 | 340,449 |
| &nbsp;&nbsp;largest prefix: multiqc (x2 keys, 10,270 own inodes each) | 55,683 | |
| `/share/maize/frodrig4/nf_work` (all gate / dev / test runs) | 82,409 | 83,258 |
| `/share/maize/frodrig4/novogene_xfer` | 2,404 | |
| frodrig4 total | ≈ 259 K | 515,312 |
| rest of the group (directories not readable by frodrig4) | ≈ 325 K | not attributable |

- The 12 prefixes the CRAM workflow uses (`conf/env_prefixes.config` + the nextflow launcher) hold ~123 K entries but ~30 K own
  inodes (`find ! -type f -o -type f -links 1`); the rest are pkgs-cache hardlinks.
- A production library leaves ~900 files in `work/` (Gate 1: 881 files / 76 tasks, independent of depth); a wave of 4 ≈ 4 K.
  `nf_work`'s 82 K are finished test runs (cachetest 20.5 K, b1g1 13.8 K, genotype_import_dev 13.0 K, …).
- Conclusion: the dominant footprint is **software** (conda), not pipeline execution; the quota is not blocking the CRAM workflow
  today (416 K free), but every env change adds a 2–10 K-inode prefix and nothing is ever removed automatically (32 prefixes now).
  A SIF is one file.

## 3. Findings

1. **Apptainer is available on compute nodes** (module `apptainer/1.4.2-1`, also 1.2.2-1; job 993008 on c207n02):
   `allow setuid = no` (unprivileged / user-namespace mode), `enable fusemount = yes`, `enable overlay = yes`, `mount home/tmp = yes`.
   So the deviation text "Hazel compute nodes … run no container engine" (`.nf-core.yml`, `docs/usage.md`, PLAN §2, nfcore-compliance
   skill) is wrong and must be rewritten whatever this branch decides.
2. Compute nodes are offline (`NXF_OFFLINE=true`): images must be downloaded by an xfer job into `apptainer.cacheDir` beforehand, as
   the conda prefixes are built by `scripts/build_envs.sbatch`.
3. The 5 installed nf-core modules (CUTADAPT, FASTQC, MULTIQC, PICARD_COLLECTWGSMETRICS, SAMTOOLS_STATS) already carry
   `container` directives with **direct SIF URLs** (`https://community-cr-prod.seqera.io/docker/registry/v2/blobs/…/data`):
   one HTTPS download per image, no OCI layer conversion, no apptainer layer cache.
4. The 7 local modules (DEMUX, MERGE_LANES, ALIGN_MARKDUP, MARKDUP_IMPORT, DEMUX_QC, PROVENANCE, REGISTRY) have no `container`
   directive, only pinned `environment.yml` (version + build).
5. Slurm settings (`conf/hazel.config`, `normal.config`, `short.config`) are independent of the software source. Profiles apply in
   declaration order (`nextflow.config`), so a container layer declared after `hazel` can switch conda off without editing it.
6. PROVENANCE records tool versions (`versions.yml`) but not the software source (prefix sha8 / image digest): needed once the
   store holds CRAMs made both ways.
7. Not everything is conda: the genotype modules `rtiger` (nilHMM from GitHub) and `crisp` (CRISP compiled from GitHub) run a
   `build.sh` on top of their conda env. Their images need a Dockerfile (§5 P3b); every other module is pure conda.

## 4. Cache and resume

- Today the conda prefix path is in every task hash; with containers the image string replaces it. **Every task hash changes**: a
  `-resume` of an existing session reruns every task not protected otherwise. This is expected (Nextflow docs, `nextflow-cache`
  skill); no hash or cache-metadata manipulation.
- Finished work is protected by the pipeline's own state, not the cache: stored + verified CRAMs are skipped (`zgIsStored`), stage 2
  reads the FASTQ checkpoint, demux QC / provenance / registry are made only if missing. Only libraries **in flight** lose work.
- Rule: switch software source **between waves**, never inside one; never `-resume` a conda session with the container profile.
- Real risk = scientific, not cache: a store mixing conda-made and container-made CRAMs. Covered by §5 P4 (provenance) and P5
  (equivalence).

## 5. Steps

Nothing is deleted by any step; every removal is a separate, consented action (`CLAUDE.md`).

**No code change**
- **(a) Stale prefixes** (authorised 2026-09-29; job 993243, `agent/20260929_231000_list_stale_envs.sbatch`): in the hazel
  checkout, after `git fetch`, `scripts/build_envs.sh --prefixes`, `--list-stale --all-refs`, `--inodes`, plus the pkgs files no
  prefix links to. Output: which prefixes no branch references and what removing them (and `conda clean`) would free. Result: §6.
- **(b) SIF smoke test** (authorised 2026-09-29; xfer job 993245 → short job 993246, `agent/20260929_231000_{pull,exec}_test_sif.sbatch`):
  download the SAMTOOLS_STATS SIF into `/share/maize/frodrig4/apptainer/cache`, then on a compute node `apptainer exec --no-home
  --pid -B /share/maize/frodrig4,/rsstu/users/r/rrellan/BZea`: tool runs, `/rsstu` reference readable, `TMPDIR` on `/share`
  honoured, SIF mounted (squashfuse / loop), no inodes created in the cache dirs, `~/.apptainer` or `/tmp`. Result: §6.
  Pass criterion: all of the above; any failure stops the branch at this point.

**Configuration only** (after (b) passes)
- **P2** `conf/apptainer_hazel.config`, profile `apptainer_hazel` declared after `hazel` and before `stub` in `nextflow.config`:
  `conda.enabled = false`, `apptainer.enabled = true`, `apptainer.autoMounts = true`, `apptainer.cacheDir =
  '/share/maize/frodrig4/apptainer/cache'`, `apptainer.runOptions = '-B /share/maize/frodrig4,/rsstu/users/r/rrellan/BZea'`,
  the apptainer module's `bin` on the head job's PATH (`scripts/submit_head_job.sbatch`). No change to executor, queues, resources.
  `scripts/pull_images.sh` + `.sbatch` (xfer job; like `build_envs.sh`: content-addressed, never deletes, manifest with sha256):
  first test whether `nextflow inspect -concretize -profile hazel,apptainer_hazel` fetches the SIFs; else download each URL under
  the name Nextflow derives from it. `scripts/run_checks.sh`: every process resolves to an image present in the cache.
  Validation: `-profile hazel,apptainer_hazel,stub` and a Gate 0 run with no "Pulling" / download line in `.nextflow.log`.

**Process definitions and software**
- **P3** Images for the pure-conda local modules — the CRAM workflow's 7 and, after the genotype merge, the genotype modules
  without a `build.sh` — from their pinned `environment.yml` (Seqera Containers: Docker + SIF URL from the same conda specs;
  the two `build.sh` modules: P3b); add the nf-core `container` ternary to each `main.nf`. Compare every image's package list (`conda-meta`) with its
  prefix's `conda list --explicit` (the nf-core module ymls pin versions only: their image builds may differ from our prefixes).
  nf-test, lint, `run_checks.sh`; CodeRabbit before any costly run.
- **P3b Custom images for the software that is not on conda** (added 2026-09-29, user decision: nilHMM stays off conda until it
  is on CRAN; containerisation does not wait for CRAN). Two genotype modules install code from GitHub with a `build.sh` on top of
  their conda env (scan of `origin/genotype`): the module `rtiger` installs **nilHMM** (the lab's R package; the RTIGER-style
  caller is a method inside it — the old Julia RTIGER package is not used; module name `rtiger` is the genotype session's call),
  and `crisp` compiles **CRISP** (vibansal/crisp @ 1a9027e). Seqera Containers builds only from conda/pip packages, so these two
  get a Dockerfile.
  1. **nilHMM releases** (in `sawers-rellan-labs/nilhmm`, public): every version the pipeline uses is a git tag `vX.Y.Z` whose
     `DESCRIPTION` `Version` matches, with a GitHub release. Found 2026-09-29: the pipeline pins 248e67e (`main` HEAD), which is
     **49 commits after tag `v0.3.0`** while `DESCRIPTION` still says 0.3.0 — two different codes under one version. First
     release: bump `DESCRIPTION` to the next version (number: user's choice, e.g. 0.3.1), tag, release; the only difference from
     248e67e is `DESCRIPTION`, so the code is the one the benchmark ran.
  2. **Pin the tag in zealgt**: `build.sh` downloads the tag's tarball, checks its sha256 and asserts `packageVersion` = the tag
     (today: commit 248e67e and `== "0.3.0"`). New prefix and task hashes for that module (fine after the benchmark record).
  3. **Dockerfile per module** next to its `environment.yml` (`modules/local/<module>/Dockerfile`): `FROM` a micromamba base pinned
     by digest; install the same `environment.yml` into the image's base env; run the **same `build.sh`** (`CONDA_PREFIX=/opt/conda`,
     `ZG_BUILD_DIR` a temp dir). One recipe feeds both the hazel conda prefix and the image.
  4. **Image build by GitHub Actions** (`.github/workflows/build_images.yml`, the first workflow in `.github/`; P7 adds the check
     jobs beside it): on a change to those module dirs or by manual dispatch, `docker build` (linux/amd64), push
     `ghcr.io/sawers-rellan-labs/zealgt-<module>:<version>-<sha8 of recipe content>` (content-keyed, like the env prefixes), build
     the SIF from it with Apptainer in the job and push it as `oras://ghcr.io/sawers-rellan-labs/zealgt-<module>:<tag>-sif`. GHCR
     packages public (the repository is), so hazel downloads without credentials; `scripts/pull_images.sh` fetches the SIF as one
     file (no docker:// conversion on hazel, no layer cache).
  5. The module's `container` directive: the nf-core ternary with the `oras://` SIF and the GHCR Docker image.
  6. Validation: smoke test inside the image (`packageVersion("nilHMM")`, `CRISP` runs), then P5 equivalence against the conda
     prefix on the genotype Gate 1 fixture.
  - **Later, after CRAN accepts nilHMM**: an `r-nilhmm` recipe on conda-forge (`grayskull` from CRAN; their bot follows new CRAN
    versions); the module becomes pure conda, joins the Seqera Containers route, and its Dockerfile goes. Optional meanwhile:
    `sawers-rellan-labs.r-universe.dev` (builds from GitHub, runs `R CMD check` on every push, no approval) as CRAN preparation.
    CRISP stays a custom image unless someone writes a bioconda recipe.
- **P4** PROVENANCE records the software source per step (image URL + sha256, or prefix sha8).
- **P5 Equivalence**: Gate 1 fixture / subsample under conda and under Apptainer; equal: decompressed FASTQ md5 (gzip bytes may
  differ), `samtools view | md5` of CRAM records, samtools stats / Picard metrics, `versions.yml`. Then a containerised Gate 2
  library (CodeRabbit first).
- **P6** Merge into `main`; containers become the hazel default between two waves. Rewrite the "No containers" deviation in its 4
  places (`.nf-core.yml`, `docs/usage.md`, PLAN §2, nfcore-compliance skill); re-enable the `container_configs` lint if applicable.
  Conda prefixes stay as fallback until the containerised Gate 2 passes; then removal of prefixes / pkgs with consent, and
  `mmlsquota` before / after.

**CI** (after P6; added 2026-09-29)
- **P7 GitHub Actions CI** (removes the "No GitHub Actions CI" deviation). The deviation's reason ("private offline cluster") does
  not hold: CI runs on GitHub's runners against `tests/fixtures`, never on hazel, and the repository is public (Actions minutes
  free). What actually blocked it: no containers (every conda env built on each run), and the nf-test stub snapshots recorded with
  the laptop's version shims (`agent/stubbin`, untracked; stub runs still evaluate each tool's version). With P3's images the real
  tools print the pinned versions, so no shims.
  - `.github/workflows/`: a **lint** job (`scripts/run_checks.sh --quick`: registry rebuild, env-prefix config, nf-core lint,
    schema lint, nextflow lint, no `task.*` in `ext.args`) and an **nf-test** job (`nf-test test` with `-profile docker` on the
    fixtures, stub + real-mode tests; pinned `NXF_VER` = the hazel launcher's). Start from the nf-core template's workflow files
    (`nf-core pipelines sync` / template), keep only these jobs; drop the AWS / release / download ones.
  - `scripts/check_resources.sh` and the env-prefix checks read config only: run them in the lint job too (hazel paths are strings).
  - Branch protection on `main`: merge only when both jobs pass (GitHub repository setting, user action).
  - Remove the `.github/*` entries from `.nf-core.yml` `lint.files_unchanged` / `files_exist` as far as the restored files allow.
  - Rewrite the deviation in its 4 places (`.nf-core.yml`, `docs/usage.md`, PLAN §2, nfcore-compliance skill);
    `docs/CONTRIBUTING.md`: `run_checks.sh` stays the pre-push check, CI enforces it.
  - Validation: a PR with a deliberate lint error and one with a broken snapshot both fail CI; a clean PR passes; timings noted.

## 6. Results

**(a) Stale prefixes (job 993243): nothing is removable now.** `--list-stale --all-refs` lists no prefix: the 11 CRAM-workflow
prefixes are referenced by `main`, and **all 21 others by `origin/genotype`** (ebba2b4, not merged into `main`), which still uses the
older per-module key scheme (`<module>-<sha8>`, e.g. `multiqc-d177f136`, `fastqc-97b011d5`) and has queued jobs on hazel
(WITNESS_POOL, 2026-09-29). (The job's `git fetch` failed: compute nodes are offline; refs are those of the last fetch, and match
the local `genotype` worktree.) What pruning could free later, once `genotype` moves to `main`'s content-keyed prefixes:
- genotype prefixes whose content duplicates a CRAM-workflow prefix (align_markdup, demux, demux_qc, fastqc, markdup_import,
  multiqc, picard_collectwgsmetrics, provenance, registry, samtools_stats) + trimmomatic + the old nextflow launcher: **≈ 34.6 K
  own inodes** (multiqc-d177f136 alone 10,270);
- pkgs-cache files no prefix links to (`conda clean`): **8,263** (of 88,934 pkgs inodes).
So pruning frees ≈ 43 K at most; the genotype-only envs (crisp, rtiger, chromosome_painting, allele_counts, bcftools_view,
mask_read_starts, pooled_likelihood_tiers, read_position_qc, witness_pool; ≈ 20 K own) stay while that workflow uses conda.
The full ≈ 170 K comes back only if **both** workflows move to containers.

**(b) SIF smoke test: PASS** (xfer job 993245, compute jobs 993246 and 993254 on c203n12 / offline).
- Download: the SAMTOOLS_STATS SIF URL is a plain SIF file (108 MB, 1 s, sha256 = the URL's blob digest `e994bf4e…`), saved as
  `/share/maize/frodrig4/apptainer/cache/community-cr-prod.seqera.io-docker-registry-v2-blobs-sha256-e9-e994bf4e…-data.img`:
  **1 inode**. No OCI conversion, apptainer layer cache unused.
- `apptainer exec --no-home --pid` (module 1.4.2-1) on an offline compute node: `samtools 1.24 / htslib 1.24`; `TMPDIR` on `/share`
  honoured (`mktemp` in it); rootfs = read-only overlay from the system session dir (`/usr/local/apps/…/mnt/session`, not our
  quota); **no inode created** (cache dir, `APPTAINER_CACHEDIR`, `~/.apptainer`, `/tmp` counts unchanged before/after).
- **Bind must be `/rsstu/users/r/rrellan/BZea`, not `…/BZea/ZEAL`**: `ZEAL/reference/B73.fa` is a symlink to `../../ref/…`, invisible
  under a ZEAL-only bind (job 993246 failed on it; 993254 with the BZea bind read `B73.fa.fai` and `samtools faidx chr1:1-60`).
  P2 uses `apptainer.runOptions = '-B /share/maize/frodrig4,/rsstu/users/r/rrellan/BZea'`.
- Still open for P2: the file name Nextflow's apptainer cache expects for an `https://` image (the name used here is a guess).

## 7. nf-core status after this branch

- Meets the nf-core software requirements (conda + Docker + Singularity/Apptainer per module) once P3 is done.
- Remaining documented deviations (unchanged, `.nf-core.yml`): no GitHub Actions CI, build-pinned conda prefixes on hazel (only
  if the conda path stays in use), cache test as an operator script, store + checkpoint outside `--outdir`, `versions.yml` in
  five local modules, stage-2 samplesheet written by the pipeline, integer-or-string CLI params, per-source read structures, CRAM only.
- Containers make GitHub Actions CI possible (nf-test with Docker on the bundled fixtures): planned as P7, which removes the
  "No GitHub Actions CI" deviation.

## 8. Alternatives considered

- Pruning only (stale prefixes, finished test `work/` dirs, with consent): frees tens of thousands of inodes without code change,
  but not the growth (one prefix per env change). Worth doing regardless: (a).
- Containerise only MULTIQC (largest env): rejected, mixing conda and containers per process under one profile is fragile.
- Squashed conda envs / conda-pack: re-implements a container runtime; rejected.
