# PLAN: containers on hazel (Apptainer)

Branch `containers`. Simplified 2026-09-29 (user): the minimal nf-core route, nothing more. Starts after the genotype branch is
aligned with `main` and merged (merged 2026-09-30, PR #1). **Status 2026-09-30:** steps 1-5 done (results §7); the switch goes to
`main` by PR. Cleanup after the switch: docs/PLAN_cleanup.md.

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
   `pkgs` cache and check the quota (`mmlsquota -g maize gpfsHPCcommon2`) (docs/PLAN_cleanup.md, cleanup 1).
   **Logging in the templates** (`CLAUDE.md`, "Logging in task scripts"; user, 2026-09-30), done in the same commit set
   because the switch changes every task hash anyway, so it costs no extra reruns: the 21 Python templates move to
   `logging` (timestamped, tagged, stderr), the 2 R templates (RTIGER, CHROMOSOME_PAINTING) to `logger` (`r-logger` added to
   their environment.yml / the nilHMM Dockerfile, new images), and every step that can run longer than a minute at genome scale (e.g.
   POOLED_LIKELIHOOD_TIERS, GAP_FILLING_*, RTIGER per line) logs progress with a running ETA about once a minute (time-
   throttled; less often only if logging becomes an I/O issue). Outputs must stay byte-identical: only
   stderr changes, checked by rerunning the module nf-tests (snapshots) and one Gate 1 comparison.

## 6. Later, optional

- **GitHub Actions CI**: lint + nf-test with Docker on the test fixtures (the repository is public, so it is free). Removes the
  "No GitHub Actions CI" deviation. Possible only once step 2 exists.
- PROVENANCE records the image of each step (useful when the store holds CRAMs made with conda and with containers).
- **Nextflow launcher without conda** (user, 2026-09-30: option B). After the switch the only conda env left is the
  launcher (`envs/nextflow`: nextflow 26.04.6 + openjdk 25, ≈ 8,000 files, 2,966 of its own), because the head job runs
  on the host, outside any container (it submits every task with `sbatch`). Replace it with Nextflow's single-file
  launcher `nextflow-26.04.6-dist` (all libraries in one executable; sha256 checked) plus a **pinned Java runtime of our
  own** (e.g. Eclipse Temurin 21 JRE, archive sha256 checked, unpacked once on `/share`, ≈ 300 files), and the nf-schema
  plugin installed next to it as `envs/nextflow/build.sh` does today; one xfer job. `scripts/submit_head_job.sbatch` puts
  the launcher on PATH and sets `JAVA_HOME` to that runtime; `NXF_OFFLINE`, `NXF_PLUGINS_DIR` and `NXF_VER` stay. Not
  hazel's `java/17` module (option A): site modules can change or break (the apptainer module already fails without
  `TMPDIR`). Not Nextflow in a container (option C): `sbatch` from inside a container needs the host's Slurm binaries,
  libraries and munge socket. With it the project uses no conda at all.
  **Test** (only the head job changes: Java, the Nextflow binary, the plugin, submission; the tasks keep their images):
  1. *No conda:* the new head job drops hazel's miniconda from PATH (today added for activating prefixes), so any hidden
     conda use fails loudly. A short compute-node job checks `java -version` (the pinned runtime), `nextflow -version`
     (26.04.6), `command -v conda` (nothing), and `nextflow config -profile hazel,apptainer_hazel` with nf-schema loaded
     offline from our plugins dir.
  2. *Gate 0 of every entry* (3 CRAM + 7 genotype, stub) with the new launcher: submission, polling, publishing, the store
     guards.
  3. *Cache:* `-resume` a finished Gate 1 run (e.g. `containers_g1`) with the new launcher: every task cached, 0 submitted
     (same task hashes, so swapping the launcher between waves reruns nothing; `scripts/test_cache.sh` style check).
  No Gate 1: the tasks' software does not change.

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

**Step 4, genotype workflow** (run card `docs/runs/containers_genotype_gate01.md`; containers code ffcbf01, baseline the
stored conda run `gate1_mex2_port_r1`, code = `main` apart from 14 meta.yml files):
- Gate 0, 7 entries (jobs 1000754-1000760): SUCCESS, 51 tasks, every one via `apptainer exec` (CRISP and RTIGER from the
  GHCR images), 0 "Creating env", 0 pulls.
- Gate 1, first attempt (key `_r1`, jobs 1000989-): stage 2 failed, `cmp: command not found` in ALLELE_COUNTS; an audit of
  every host program named in each module's script/stub against its own SIF (job 1001550) found only this one; diffutils
  added (ffcbf01, with the 10 s polling). Rerun under key `gate1_mex2_containers_r2` (jobs 1002943-1002949): all 7 SUCCESS,
  **21 min 21 s** (conda chain 46 min; per stage 40-55 % of the old time, the polling change).
- Comparison (jobs 1003117 + a recount on this run's traces only): **70 = 70 files; 56 byte-identical, 4 identical after
  decompression** (the step-4 `sites.tsv.gz`: gzip write time); `rtiger.versions.yml` differs only in `nilhmm 0.3.1` vs
  `0.3.0` (same code); `union/*.per_donor.tsv` only in `table_sha256` of the compressed step-4 files (all counts equal);
  the 7 `settings/*.json` in store key, session and module code hashes (the container lines). RTIGER segments, genotype
  calls, gap filling and union identical. Task counts identical for all 27 processes; peak RSS within ~10 MB except tiny
  tasks (POOLED_LIKELIHOOD_TIERS 2,458 MB in both; CRISP 178 / 178 MB, 60 / 76 s; RTIGER 128 / 129 MB).

**Step 4 done: both workflows pass Gate 0 and Gate 1 on containers with results identical to conda.**

**Step 5, the switch** (code 7813ea3 part A, 2966508 part B, d94158f part C, b0e83b1; hazel checkout at f5d4e83; run card
`docs/runs/containers_switch_gates.md`):
- `-profile hazel` = Apptainer; the `apptainer_hazel` profile, `conf/env_prefixes.config`, `envs/process_aliases.tsv` and
  the module conda builds removed; CRISP and RTIGER container-only (conda profile refused). The four deviation texts
  rewritten.
- Logging in all 23 templates (Python `logging`, R `logger`; stderr, timestamped, tagged; time-throttled progress with an
  ETA). New images: CHROMOSOME_PAINTING (Seqera, + r-logger) and `ghcr.io/sawers-rellan-labs/zealgt-nilhmm:0.3.1-1`
  (GitHub Actions run 36795073288), downloaded and checked inside the SIF on hazel (job 1004829: bash, touch, cat, ps,
  Rscript; logger 0.4.3, nilHMM 0.3.1, data.table, ggplot2).
- `--input` no longer validated at start-up (`samplesheetToList` validates it where it is read; ≈ 3.5 s per genotype head
  job; docs/PLAN_cleanup.md §5).
- Found on the way: `scripts/check_resources.sh` was broken since part A (its laptop stubs used hazel's Apptainer cache
  dir); Apptainer off in its override.
- Laptop: lints, nf-test 71/71 stub, the resource check, real module nf-tests 34/34 on the production images (Docker,
  linux/amd64). CodeRabbit on de627cf..d94158f (executing code): 0 findings; a grep for removed names found one stale
  `meta.yml` line (fixed, b0e83b1).
- **Gate 0** on the plain profiles (jobs 1004869-1004877): all 9 runs SUCCESS, every task via `apptainer exec`, 0 "Creating
  env", 0 pulls; task counts as step 4 (CRAM demux 79, genotype 51). The markdup_import stub ran on the full dev sheet
  (379 tasks, 30 min); its Gate 0 now uses a 3-row sheet (`docs/runs/gate0/cram_gate0_import.csv`).
- **Gate 1** vs the step-4 container runs (jobs 1005050-1005057, comparison 1005078): CRAM `switch_cram_g1` 17:49 (step 4
  25:51), genotype chain ≈ 20 min.

| check | result |
|---|---|
| CRAM task counts | identical, 79 tasks in 11 processes |
| CRAM alignment records, 12 samples (`samtools view -T`, md5) | identical; file bytes differ by 8 bytes per CRAM: the header records the run's own paths (`switch_cram_g1` is 1 character longer than `containers_g1`), so byte identity is not expected (the card's wording was wrong) |
| CRAM store, 80 other files | 42 byte-identical; Picard WGS metrics, markdup stats, registry identical after dropping dates/paths; `provenance.json` only run fields (code version, run/session id, paths, profile, write time); demux cutadapt log only its timing lines |
| tool versions | identical |
| genotype files | 70 = 70; 58 byte-identical, 4 identical after decompression (step-4 `sites.tsv.gz`, gzip write time); `union/*.per_donor.tsv` only the sha256 of those gz files (counts equal); the 7 `settings/*.json` only key, session and module code hashes (the templates changed) |
| genotype task counts | identical for all 27 processes; peak RSS and time within noise |
| logging (`.command.err`) | every genotype template process writes timestamped, tagged lines; DEMUX_QC, PROVENANCE and REGISTRY set up a logger but have nothing to log yet (only their `sys.exit` errors); no progress/ETA lines: no template task ran ≥ 1 min at Gate 1 (longest POOLED_LIKELIHOOD_TIERS 18 s), so the throttled progress is first seen at genome scale |

**Step 5 done: on the plain hazel profiles both workflows pass Gate 0 and Gate 1, outputs unchanged by the logging.**
Next: PR to `main`, then cleanup 1 (docs/PLAN_cleanup.md) and the CRAM Gate 2 restart on containers.

**Step 6, whole chr10 on containers** (2026-10-01; `main` 79f877a, card `docs/runs/genotype_chr10_mex2.yml` unchanged, key
`chr10_mex2_containers_r1`, jobs 1016495-1016501; baseline the conda run `chr10_mex2_port_r1`, code 9377898; comparison job
1017114, `agent/20261001_134500_compare_chr10.sbatch`):
- All 7 entries COMPLETED, 34 min end to end (conda: 58 min, all of the difference the 1 min -> 10 s polling; task realtimes
  equal, e.g. CRISP 448 / 444 s).
- Store 70 = 70 files: 55 byte-identical, 3 identical after decompression (gzip write time); the expected differences
  (settings key / session / code hashes, `rtiger.versions.yml` nilhmm 0.3.1 vs 0.3.0, `per_donor.tsv` sha256 of the step-4
  files). Task counts identical for all 27 processes; peak RSS within noise.
- **One real difference, one read:** Zx.0540_P3 chr10:126,660,388, pool S_2B_8: CRISP counted one overlapping-mate REF read
  fewer (DP 7 vs 8, ADb 2,0 vs 3,0), carried into that donor's step-4 site line and `pool_qc` (REF reads 224,422 vs
  224,423). No call changed (same AC, filter, tier); union, donor alleles, gap filling, ancestry, genotypes and raster
  identical; the zealbc1 accuracy reports of both donors identical except that depth sum. Zx.0570_P2: all 82,765 CRISP
  records identical.
- **Cause: CRISP is occasionally non-deterministic there, not the migration.** The pipeline task's exact CRISP command rerun
  twice on the same inputs and image (job 1017349) gave DP 8 / ADb 3,0 both times, as both conda runs (`chr10_mex2_r1`,
  `_port_r1`): 4 of 5 runs agree, one container run differs. Known issue for reruns of the same key; stored outputs are
  fixed by the store and its settings guard. Not investigated further (dev scope).
- Logging: every template writes timestamped, tagged lines; no progress/ETA lines, none expected: no template task ran
  >= 1 min even on the whole chromosome (longest POOLED_LIKELIHOOD_TIERS and GAP_FILLING_LINES, 22 s).

**Container migration checked end to end on a whole chromosome: outputs unchanged.**

**Restore script** (2026-10-01; `scripts/restore_images.sbatch`, handover 2026-09-30 "Next" step 3; /share deletes files
unread for 30 days). Xfer job, idempotent: the images from the modules' own `container` lines (37 modules, 18 distinct images,
the 18 in hazel's cache), each missing one fetched (curl / `apptainer pull --disable-cache`) and checked as a SIF, the
commands each fetched SIF needs checked inside it, the launcher rebuilt only if its prefix is absent. Replaces the scratch
download scripts. Tests on hazel (submitted from the laptop file via stdin, hazel checkout `main` e27c56f untouched):
- Job 1017971 `--check-all`, full cache: 0 fetched, launcher ok (26.04.6, nf-schema 2.5.1); the command check took every
  word of the scripts and flagged words that are host programs on the xfer node (`as`, `file`, `view`, `conda`, from
  messages and arguments): false alarms. Fixed: only words in command position, plus the commands spliced in by `def`
  strings (DEMUX's `tar -xOf`) and the versions `eval(...)` commands.
- Job 1018005 `--check-all`: all 18 SIFs 0 missing, launcher ok, exit 0, 11 s.
- Job 1018060, the python SIF (`…eab5e327…`) renamed to `.aside` (user's OK): fetched that one (144 MB, 2 s), byte-identical
  to the `.aside` copy (`cmp`), its 13 modules' commands present, exit 0.
- The host-PATH filter of those runs (as the 2026-09-30 audit, job 1001550) left tools only in the images (samtools,
  minibwa, bcftools, CRISP) unchecked. Replaced by an ignore list: every command-position word that is not a shell
  builtin/keyword, a name the module defines, or a `CMD_IGNORE` word (Groovy/heredoc values: `END_VERSIONS`, `ZG_EOF`,
  `bc1_sample`, `csi`, `tbi`) is checked inside the image; the parser reads only the shell text of the script blocks and
  the string literals of Groovy assignments.
