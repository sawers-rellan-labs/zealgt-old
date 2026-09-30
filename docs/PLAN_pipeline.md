# Plan (DRAFT) — pipeline v2: one Nextflow pipeline from raw libraries to ancestry and imputed genotypes

Status: **proposal, 2026-09-24**, for discussion; nothing implemented. Storage section (§5) filled from the disk audit
(`nilhmm/bin/audit_du.sbatch`, job 946049, results in `ZEAL/results/audit_du_20260924/`).

## 0. First work in zealgt (user, 2026-09-24): no more demultiplexing of the libraries already in use
Demultiplexing is the most expensive step to repeat. In the nilhmm runs, pool 1B was demuxed ~9 times during the 09-11 → 09-14 gate runs,
and every other library was demuxed once but only its donor's samples were aligned, leaving ~2.8 TB of FASTQs for unaligned samples in
`work/` (§5). Nextflow did not prevent this: `workDir = ${params.outdir}/work` gave every new outdir an empty cache, demux FASTQs were not
published, and hash changes between tries reran DEMUX. These two tasks come before any other zealgt work.

### Development starting data (ready, 2026-09-24)
Two mexicana donors with 5 BC1 samples each (the QC-set design: 5 pools per founder), fully demultiplexed and aligned, all files and
indexes checked on hazel:

| donor | BC1 samples (`results/cram/`) | BC1 total λ | BC2S3 lines (0.4×, realigned) | demux QC rows | discovery |
|---|---|---|---|---|---|
| Zx.0540_P3 | S_2A_3, S_2A_11, S_2B_8, S_2F_1, S_2F_12 | 43.2× | 40, `results/bench_zx0540_chr10/bc2s3_realign/cram/` | `results/bench_zx0540_chr10/` | chr10 done with the CRISP fix (job 949447, tier A 40,941; pre-fix 944798 in `discovery/Zx.0540_P3_preBEDfix/`) |
| Zx.0570_P2 | S_2H_1, S_3B_11, S_3C_9, S_3D_8, S_3E_7 | 43.7× | 44, `results/bench_zx0570_chr10/bc2s3_realign/cram/` | `results/bench_zx0570_chr10/` | chr10 done with the CRISP fix (job 949448, tier A 54,395) |

Plus the B73 controls (`results/b73_control/`: ERR3288215 15.5×, skim10 5.7×). These 10 BC1 CRAMs and 84 line CRAMs were made by
nilhmm / `bc2s3_realign.sbatch` (minibwa -x sr, MAPQ 20, `-F 0x904`) **without duplicate marking and without read groups**, so they are
the first imports: MARK_DUPLICATES + read-group pass (Task 2), then zealgt's own variant discovery. The existing Zx.0540_P3 discovery
table predates duplicate marking and serves as the before/after comparison, not as zealgt input. Compare against the rerun
with the CRISP BED-end fix (§4 #9), not the pre-fix table (`discovery/<donor>_preBEDfix/`), so the comparison measures duplicate marking only.

### Task 1 — turn the existing demux FASTQs into CRAMs, once
Align every not-yet-aligned sample of the libraries that are already demuxed, from the FASTQs still in the nilhmm `work/` directories
(by `-resume` in the original launch directories, so the cached DEMUX tasks are reused, or by an alignment job reading those FASTQs
directly), with duplicate marking; write the CRAMs to the store.

| libraries demuxed | samples | aligned (2026-09-24) | to align | FASTQs now in |
|---|---|---|---|---|
| BC1 1B | 12 | 12 (`results/align_membench`) | 0 | `results/gate2/work` |
| BC1 4E, 4F, 4G | 36 | 4 (Zv.0490_P4) | 32 | `results/work` (launch `results/pool_run_4E4F4G`) |
| BC1 1A | 12 | 1 (S_1A_4) | 11 | `results/work` (launch `results/pool_run_1A`) |
| BC1 2A, 2B, 2F | 36 | 5 (Zx.0540_P3; CRAMs checked 09-24) | 31 | `results/work` (launch `results/pool_run_2A2B2F`) |
| BC1 2H, 3B–3E | 60 | 5 (Zx.0570_P2; CRAMs checked 09-24) | 55 | `results/work` (launch `results/pool_run_2H3B3C3D3E`; other session's run — its decision) |
| BC2S3 batch-2 rows V22A–H, V23A–H, V24A–B | 216 wells | ~30 lines + checks | ~185 | `results/bc2s3_batch2/work` |
Scale: ~130 BC1 samples (~1 h × 8 cpu each, ~1,000 CPU-h) and ~185 lines (minutes each). **Until this is done and verified, those `work/`
directories are the only copy of the demuxed reads and must not be cleaned.** Done = every sample of these libraries has a verified,
non-empty CRAM in the store; then the FASTQs can go (§5, cleanup group A–C).

### Task 2 — make repeated demultiplexing impossible by construction
- **Development starts from CRAMs.** Development entries take a sample sheet of existing CRAMs; `read_demultiplexing` is not part of them.
- **Demux registry in the store.** A library is registered as done when its demux QC table and all its sample CRAMs are in the store.
  `read_demultiplexing` refuses a registered library unless it is named explicitly with `--force-demux <library>`.
- **One pass per library** for any library demuxed from now on: the library is demultiplexed once — one DEMUX task per library ×
  lane on the delivered lane files (cutadapt takes one input file per read; streaming the lanes through a pipe failed, Gate 2 job
  972171, 2026-09-28), then MERGE_LANES concatenates each sample's lane outputs (`cat` of gzip members) — and **all** its
  samples then go through CUTADAPT → FASTQC → ALIGN_MARKDUP as per-sample processes that write the CRAMs to the store (user,
  2026-09-27: one process per tool so every module carries its own pinned environment; replaces the single DEMUX+ALIGN task). FASTQs
  pass through `work/` on /share; each sample's trimmed pair is hardlinked into the FASTQ checkpoint and kept there until all the
  library's CRAMs are stored and verified (§3, §5 rules 3–4; user, 2026-09-29). `--samples` never restricts which samples of a demuxed
  library get aligned.
- **Reuse of existing outputs:** entries read existing CRAMs / tables through sample sheets; the workflow computes only what is missing
  in the store; CRAMs imported from nilhmm (made without duplicate marking) get a MARK_DUPLICATES-only step, not a realignment.
- **Raw libraries are read-only inputs.**

## 1. Why
The chr10 pilots ran as standalone sbatch scripts next to the `nilhmm/` pipeline. The same step was implemented more than once and the
copies drifted: B73 pools inside vs outside CRISP, `mpileup -I` present in one pileup and missing in another, a demux QC table overwritten
by every pool run, no duplicate removal anywhere. Each fix had to be applied in several places. One module per step removes that class
of error. The known issues this plan must settle are in §4.

## 2. Principles

### The rerun problem these principles address
In the nilhmm runs, a costly step (demultiplexing, whole-genome alignment) that had already completed ran again after an edit that could
not change its output: a comment, a cosmetic change to a module, or a resource reallocation. Each rerun left a new set of task
directories, so `work/` multiplied for menial reasons (the audit found ~3.2 TB there, §5).

The cause is how `-resume` decides: it reuses a task only if the task's **hash** is unchanged. The hash covers the session, the full
process name, the process's script text **before** `${…}` substitution, its inputs, referenced params / globals, the evaluated `task.ext.*`
values the script reads, templates and named bin/ executables, and its environment (conda / container); directives are not hashed.
(Table corrected 2026-09-28 from a hash test on hazel, Nextflow 26.04.6, job 972453, main checkout
`agent/20260928_081500_hashtest_results.md`; sources in `agent/20260928_075824_nextflow_cache_practices.md` and the `nextflow-cache`
skill. The earlier table said `${task.cpus}` in the script reruns the task: true up to 23.04, not since 23.10, PR #4339.)

| change | reruns the task? | why |
|---|---|---|
| comment **inside** the `script:` block (bash `#`) | **yes** | it is part of the script source |
| comment **outside** it (Groovy `//` above the block) | no | not part of the script |
| `cpus` / `memory` / `time` changed, script uses `${task.cpus}` / `${task.memory}` (e.g. `-@ ${task.cpus}`, `-Xmx`) | **no** (≥ 23.10; tested on 26.04.6) | the hash takes the un-substituted source, and directives are not hashed. A cached output may still show the old value (e.g. a logged thread count) |
| the same resource change, `task.*` inside an `ext.args` closure (`ext.args = { "-t ${task.cpus}" }`) | **yes** | `task.ext.*` values are hashed as evaluated (issue #7663; test process C) |
| a `params.*` value the script reads | **yes** | hashed by value (e.g. `align_mem_reserve_gb`: a re-tune reruns ALIGN_MARKDUP) |
| edit of an **executable** bin/ script that the script names as a plain word (`helper.sh`) | **yes** | bundled scripts are hashed (test process D) |
| edit of a **non-executable** bin/ script, or one called through an interpreter by path (`bash ${projectDir}/bin/x.sh`) | **no — stale output** | not in Nextflow's bin index (test process E). On hazel `/rsstu` strips the exec bit, so every bin/ script of the checkout falls in this row |
| edit of a module template (`templates/`) | **yes** | the template text is the hashed source |
| an input file touched (new mtime), same content | **yes** by default | default cache mode includes mtime |
| the same, with `cache 'lenient'` | no | path + size only |
| process renamed or moved, another entry, a new session without `-resume <id>` | no reuse | a cache entry belongs to one process in one session (discussion #5612): the cache is not a checkpoint |
| any edit, when the task's output already sits in its `storeDir` | no | skipped whatever changed, a bug fix included; storeDir is deprecated in the 26.10 docs (PR #7574) and dropped here (principle 3) |

### Principles
1. **One module per step**, used by every entry; no standalone copies of a module's command.
2. **Separate entries per stage, with a published checkpoint between the costly stages** (the existing `--entry` dispatcher; user,
   2026-09-29): stage 1 `read_demultiplexing` hardlinks the trimmed FASTQs plus a samplesheet into the FASTQ checkpoint, and stage 2
   `read_alignment` reads only that checkpoint (§3). A fix to stage 2 is rerun as `read_alignment` alone, in any session, without
   `-resume` and without touching stage 1; editing a downstream module never puts upstream tasks at risk.
3. **Costly, reusable outputs live in a permanent store, not in `work/`**: CRAMs, per-library demux QC, provenance, registry. They are
   written by `publishDir` (`mode: 'copy'`, `overwrite: false`, `failOnError: true`) and reused by **explicit skip-if-stored logic** in the
   workflow (the `zgIsStored` pattern: a stored output is used in place of the task, which is then not created), not by `storeDir`
   (dropped 2026-09-28: deprecated in the 26.10 docs, PR #7574, whose documented replacement is this logic; it also hid a bug fix
   behind an existing output). **Never overwrite a stored CRAM:** a CRAM counts as stored only if CRAM + `.crai` exist and the CRAM
   ends with the CRAM 3 EOF container; a present but unverified CRAM (e.g. a copy cut short by a killed head job) stops the run with its
   name for the user to remove. Rerunning a stored output is a deliberate act (remove it, with the user's consent).
4. **Hash hygiene** (from the table above):
   - comments and notes outside the `script:` block (Groovy `//`), never as bash `#` inside it;
   - resources the standard nf-core way: directives in `conf/`, `${task.cpus}` / `task.memory` in the script (not hashed). The Slurm
     resource helper that read threads and memory from `SLURM_*` at run time was removed 2026-09-28: not needed on ≥ 23.10, and as a
     non-executable bin/ script it was itself invisible to the hash;
   - **no `task.*` inside an `ext.args*` closure** in `conf/*.config` (it puts resources back into the hash):
     `scripts/check_ext_args.py`, run by `scripts/run_checks.sh` (also `--quick`);
   - output-affecting helper code in module `templates/` (hashed by content), never a bin/ script run by path or through an interpreter;
     no logic hidden from the hash on purpose (maintainers call that a stale-cache bug);
   - `cache 'lenient'` (path + size, not mtime) on processes with large inputs;
   - cache behaviour is tested on the pinned Nextflow version, not assumed (§6).
5. **Temporaries die inside the task** (merged witness pool, sort temp); the exception is the demux and trimmed FASTQs, which pass
   between processes through `work/`, the trimmed pairs also hardlinked into the FASTQ checkpoint (§0 Task 2, §5 rule 3).
6. Tools: minibwa, samtools, bcftools, CRISP, nilHMM, PHG — the ones in use. **Reproducible environments** (user, 2026-09-27): every
   module carries its own pinned `environment.yml` in the repo (nf-core convention; a module whose script pipes tools together pins
   those few tools, e.g. minibwa + samtools); tools that are not conda packages (CRISP, nilHMM) get a pinned-commit
   `build.sh` in the same env; `scripts/build_envs.sh` builds them all once, as an xfer job (compute nodes are offline), into
   `/share/maize/frodrig4/conda/zealgt/` (fast GPFS; never on `/rsstu`, user 2026-09-28), and never at task time; a prefix is
   keyed on the env's content only (`<first dependency>-<sha8>`), so identical envs (the python-only modules) share one. The built
   environments **stay there**: they are never moved, rebuilt or deleted without the user (user rule; the repo can recreate them,
   which is not a licence to do so). The zealbc1-era envs are replaced; their versions are kept in `envs/legacy_zealbc1/`.

### Deliberate deviations from nf-core
Deliberate deviations from the nf-core specifications. The same list, word for word, is in `.nf-core.yml`, `docs/usage.md`,
`docs/PLAN_pipeline.md` §2 and the nfcore-compliance skill; a new deviation goes into all four, with its reason.
- **No containers** (spec: Docker / Singularity support). Hazel compute nodes are offline and run no container engine for
  this project; every module has a pinned `environment.yml` instead. The template's container configs
  (`conf/containers_*.config`) are removed and gitignored (`nf-core modules install/patch` regenerates them), and the
  `container_configs` lint test is off.
- **No GitHub Actions CI** (spec: CI testing). The pipeline runs on a private offline cluster; `scripts/run_checks.sh` runs
  the same checks on the laptop before every push (nf-core lint, schema lint, nextflow lint, nf-test, the env prefix and
  resolved-resource checks; docs/CONTRIBUTING.md).
- **Build-pinned conda prefixes set per process in the site config** (spec: conda packages pinned by version, envs created
  by Nextflow). `conf/env_prefixes.config`, generated by `scripts/build_envs.sh --write-config` and included by the hazel
  and local profiles only, sets each process's `conda` to a prebuilt prefix on `/share` (config `conda` overriding the
  module's, the standard Nextflow override). A prefix is keyed on the content of `environment.yml` (+ `build.sh`) only, so
  identical envs share one prefix; local modules pin version and build (linux-64 is the only target); the prefixes are built
  once by an xfer job (compute nodes are offline), never at task time.
- **Cache test as an operator script, not an nf-test** (spec: tests are nf-test). `scripts/test_cache.sh` resumes one
  Nextflow session across several runs (raised resources, an edited module, stage 2 alone) and compares the task hashes; nf-
  test starts a new session for every run and cannot share one.
- **Permanent store and FASTQ checkpoint outside `--outdir`** (spec: outputs published to `--outdir`). CRAMs, QC,
  provenance, demux QC and the registry are copied into `--store` (never overwritten) and the workflow skips work whose
  stored output exists; the trimmed pairs are hardlinked into `--fastq_checkpoint` (the filesystem of `work/`), with
  CUTADAPT's log (one `publishDir` map: a second one whose path uses `meta` breaks `nextflow config -o json`, so nf-core
  lint). Only reports go to `--outdir`.
- **`versions.yml` files for five local modules** (spec: versions as `eval` topic tuples). ALIGN_MARKDUP and MARKDUP_IMPORT
  publish theirs next to the CRAM, one line per tool of the pipe, because PROVENANCE of an already stored CRAM (skipped, not
  made again) needs the versions of the tools that made it; DEMUX_QC, PROVENANCE and REGISTRY are python module templates,
  and Nextflow allows `eval` outputs only with Bash scripts. DEMUX and the nf-core modules report `eval` topic tuples;
  coreutils (DEMUX's `head`, MERGE_LANES's `cat`) is pinned in `environment.yml` but not reported (the BSD tools of the
  laptop's local runs have no `--version`).
- **Stage-2 samplesheet written by the pipeline** (spec: inputs through `--input`).
  `<fastq_checkpoint>/<lib>/samplesheet.csv` is an output of stage 1 and the only input of `--entry read_alignment`,
  validated by nf-schema against `assets/schema_checkpoint.json`.
- **`--subsample` / `--max_libraries` typed integer-or-string** (spec: typed parameters). Nextflow 26 hands CLI values over
  as strings; the schema accepts digit strings and the code converts.
- **Per-source read structures as two parameters** (`read_structure_*`, chosen by `barcode_layout`), not one per sample;
  both values are recorded in every provenance record.
- **CRAM output only, no `--bam`**: the genotype workflow reads CRAM.

## 3. Two workflows, stages and modules
The pipeline is two workflows in this repository, named by their endpoints (user, 2026-09-27): the **CRAM workflow** (raw libraries → analysis-ready CRAMs) and the **genotype workflow** (CRAM store → genotype table), with the **store as the only contract** between them (decided 2026-09-24):

| | **CRAM workflow** (read processing) | **genotype workflow** |
|---|---|---|
| input | raw libraries + sample maps | the CRAM store + a sample sheet + a run card |
| runs | once per library, then done (demux registry) | many times: development, new donors, parameter changes |
| output | analysis-ready CRAMs + read/alignment QC + provenance + registry | discovery tables, markers, ancestry, imputed genotypes |
| cost | heavy (hours per BC1 library; ~3,000 CPU-h for all BC1 samples) | light per donor (minutes per chromosome) |
| profile | compute/normal, large scratch | short QOS |
Genotyping development never contains a demultiplexing or alignment step, so no edit to it can trigger one. Genotyping checks each
CRAM's provenance record against the current read-processing settings.

### CRAM workflow stop point: the analysis-ready CRAM
Per sample, into the store: CRAM + index (B73 v5, coordinate-sorted, read groups in every read, **duplicates flagged, not removed**,
all mapped primary reads, **no MAPQ filter**); per-sample QC (FastQC of the trimmed reads, `samtools stats`/`flagstat`, markdup
stats, mosdepth λ); per-library demux QC and MultiQC; a provenance record (source, demux tool, trimming parameters, aligner and
version, markdup settings, code version, and a snapshot of the sample's `meta/samples.csv` row: donor, pedigree, nil_id, taxon,
role, …; identifier rules in meta/PROVENANCE.md "Identifiers": `sample_id` is the only key, RG `ID` = `SM` = `sample_id`, one read
group per sample, no line or nil id in a CRAM header); the registry entry. MAPQ, base-quality and duplicate filters are applied by the genotype workflow at
read time (`mpileup -q20 -Q20`, CRISP `--mmq 20`), so a threshold change never needs realignment. (The nilhmm CRAMs were written with
`-q 20 -F 0x904`; new CRAMs are not.) Anything that needs reference ranges, a site panel or the pedigree belongs to the genotype workflow.

### One read-processing standard for all three sources
| source | libraries | input adapter | barcode layout | sample map |
|---|---|---|---|---|
| BC1 pools | 32 (1A–4H), `BC1_dna_raw/` | plain FASTQs | inline, symmetric on R1 and R2 (`-g`/`-G`) | `meta/bc1_well_map.csv` |
| BC2S3 batch 2 | 32 rows (V21A–V24H), `BC2S3_batch_2_dna_raw/` | plain FASTQs | inline, symmetric on R1 and R2 | `meta/bc2s3_batch2_well_map.csv` |
| BC2S3 batch 1 (CLY2023) | 17 plate pools in `sara/DNA_Sequencing_raw/BZea/NVS188B_*_R{1,2}.tar` (1.5 TB, read-only) | members streamed out of the tars (`tar -xOf`), lanes concatenated; plate pool = 6-bp Illumina index in the header | **8-bp inline barcode on R1 only** (checked 2026-09-24: top-96 5′ 8-mers cover 91.9% of reads vs 6.6% at base 31) | `BZea_Sample_ID.xlsx` (1,632 wells: barcode, plate, plate index, running number, genotype) → a well map; joins to check: plate index → `BZea<n>` files, running number → `PN<plate>_SID<n>` |
Same steps for every library, one DEMUX task per library × lane, MERGE_LANES per sample, then per-sample processes (§0 Task 2): cutadapt exact-match demux (`-e 0 --no-indels`; R1-only anchoring for batch 1)
→ cutadapt 5.2 trimming (nf-core CUTADAPT: the full TruSeq read-through adapter on each read, `-a` / `-A`; `--nextseq-trim=15`;
`-m 36`; it replaced batch 1's Trimmomatic, see *Trimming* below) →
minibwa -x sr → read groups → `samtools fixmate -m` → `sort` → `markdup -d 2500` → CRAM; demux FASTQs in `work/` only, trimmed
pairs also in the FASTQ checkpoint until the library's CRAMs are stored and verified (`work/` peak ≈ 3 × the library: lane demux +
merged + trimmed FASTQs + CRAMs; at most `--max_libraries` libraries per run, all concurrent, §5 rules 3–4). Batch 1 is demultiplexed again from the tars so all ~2,400 samples share one provenance; Nirwan's
sabre + Trimmomatic FASTQs (`sara/BZea/filtered_S/`) stay as a fallback and comparison.

**Trimming** (user, 2026-09-29): cutadapt 5.2 (nf-core CUTADAPT) replaces Trimmomatic after MERGE_LANES. Batch 1 (Nirwan) and
zealgt until then: Trimmomatic 0.39 `PE -phred33 ILLUMINACLIP:<adapters>:2:30:10 LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36`,
unpaired reads discarded. Now: the full TruSeq read-through adapter on each read (`-a` / `-A`, params `trim_adapter_r1` /
`trim_adapter_r2`), 3′ quality trimming with G as low quality (`--nextseq-trim=15`: two-colour NovaSeq X / 6000 reads, whose
poly-G tails pass Trimmomatic's quality steps), pairs dropped when a read is < 36 bp (`-m 36`), output at gzip level 4 (`--compression-level 4`); `trim_args` holds the last three.
Not replicated: LEADING:3 and SLIDINGWINDOW (cutadapt trims 3′ BWA-style); the palindrome clip becomes an adapter search per read.
Why (comparison on 8 M pairs of 5 BC1 1A samples, docs/REQUIREMENTS.md §4, meta/PROVENANCE.md): residual adapter 13-mer 0.06 vs
1.25 % of reads, 3′ partial adapter 0.003 vs 2.7 %, ~2 % more pairs kept, the same mapping, no poly-G tails, ~6× faster end to end (level 4); plus
one tool family with DEMUX, a maintained nf-core module, a MultiQC-native log, no Java heap tuning. Output at level 4 +6.8 % vs
Trimmomatic's (level 1, cutadapt 5's default, was +17 %), so the checkpoint footprint grows by that share.

**Two CRAM-workflow stages and the FASTQ checkpoint** (user, 2026-09-29; branch `simplify`, 2026-09-28). Stage 1 `read_demultiplexing`
ends in a published checkpoint: each sample's trimmed pair is hardlinked (`publishDir mode: 'link'`, same GPFS as `work/`) to
`/share/maize/frodrig4/fastq_checkpoint/<library>/` (`params.fastq_checkpoint`) as `<sample>_{1,2}.trim.fastq.gz`, together with
the cutadapt log (`<sample>.cutadapt.log`; decided 2026-09-28 for the trim reports: they stay there, not in `<outdir>`, because a
second `publishDir` whose path uses `meta` breaks `nextflow config -o json` and so nf-core lint; MultiQC in `<outdir>` keeps their
numbers, and the cleanup counts only the FASTQs), and `<library>/samplesheet.csv` is written once every sample of the library is trimmed: the absolute checkpoint
paths plus everything stage 2 needs — sample, library, source, role, donor, taxon, read group, read structure (crops already
applied), layout, barcodes, demux args, trimming settings and adapters, raw location / files / tar members, subsample, stage-1 run
id, session id, code version and tool versions (columns in `docs/usage.md`) — validated by nf-schema against
`assets/schema_checkpoint.json` (FASTQs must exist). By default the same run chains into stage 2 on CUTADAPT's channel (not the
published files: publishing is asynchronous), one command per request. Stage 2 `read_alignment` can also run alone
(`--libraries A,B`), reading only those samplesheets, e.g. after a fix to ALIGN_MARKDUP or QC; it never demultiplexes and adds no
library to the checkpoint. Both skip every sample whose CRAM is stored and verified (§2 principle 3). Guards as for the store:
`--subsample N` needs a checkpoint dir named `subsample_<N>` (and a `subsample_*` dir needs `--subsample`); stub runs need a path
component `checkpoint_stub*` outside the production checkpoint; `read_demultiplexing` refuses a library whose samplesheet was written
by another session (unless `-resume` of that session or `--force_demux`) and a request that would exceed `--max_libraries` (§5
rule 3).

| # | workflow | entry | modules | per | main output (store) |
|---|---|---|---|---|---|
| 1 | CRAM | `read_demultiplexing` (stage 1; chains into stage 2 by default) | FETCH_LIBRARY (source adapter) → DEMUX (cutadapt exact inline, one task per lane) → MERGE_LANES (per sample, `cat`) → DEMUX_QC (sums the lane reports; a stored table is used in its place) | library × lane → sample | demux FASTQs (`work/` only), `demux_qc/<library>.tsv` |
| 1b | CRAM | (step of `read_demultiplexing`; subworkflow READ_TRIMMING — the old FASTQ entry was removed 2026-09-28, its inputs no longer exist) | CUTADAPT (nf-core module; TruSeq adapter per read, `--nextseq-trim=15`, `-m 36`) → FASTQC → **checkpoint**: trimmed pairs hardlinked to `fastq_checkpoint/<library>/` + `samplesheet.csv` | sample | checkpoint FASTQs + cutadapt logs + samplesheet (on `/share`, until rule 4 of §5), FastQC report |
| 2 | CRAM | `read_alignment` (stage 2: chained after stage 1, or alone on the checkpoint samplesheets; subworkflow READ_ALIGNMENT; existing CRAMs enter through `markdup_import`) | ALIGN_MARKDUP, one process with a minibwa + samtools env: ALIGN (minibwa -x sr) → READ_GROUPS → `fixmate -m` → `sort` → **MARK_DUPLICATES** (`samtools markdup -d 2500`) → CRAM (no MAPQ filter) → SAMTOOLS_STATS + markdup stats → COLLECT_WGS_METRICS (Picard; λ = `MEAN_COVERAGE`, missing = 1 − `PCT_1X`, as the zealhmm missing-data model) → PROVENANCE → REGISTRY → MULTIQC; no mosdepth (decided, user, 2026-09-27: nothing downstream reads it); stored CRAMs skipped; the run reports per library whether its checkpoint is removable (`cleanup_status.tsv`, §5 rule 4) | sample | `cram/<sample>.cram` + QC + provenance |
| 2b | genotype | `sample_quality_control` | MIN_COVERAGE (exclude < 0.05×, below) → QC_PANEL_COUNTS (`mpileup -I` at a blind QC panel, one task per sample) → COVERAGE_QC → RELATEDNESS_QC → DONOR_CONTENT_QC | sample / cohort | `sample_qc.tsv`: pass/fail + reason per sample; discovery and every caller read it |
| 3 | genotype | `variant_discovery` | WITNESS_POOL → CRISP (BC1 samples + witness only) → BED_CLIP (`bcftools view -T`, §4 #9) → WITNESS_VETO → B73_CONTROL_COUNTS (`mpileup -I`) → POOLED_LIKELIHOOD_TIERS | donor × chr | `step4/<donor>.sites.tsv.gz` |
| 4 | genotype | `ancestry_inference` | LINE_ALLELE_COUNTS → RTIGER (own tier-A sites, rigidity 500, run as in zealbc1 — §4 #10). Needs only stage 3, not the union | donor × chr | ancestry segments per line |
| 5 | genotype | `marker_union` | MARKER_UNION (tier-A sites of the donor set; multi-allelic dropped) | donor set × chr | `union/<set>_<chr>.tsv.gz` |
| 6 | genotype | `donor_allele_calling` | two-step gap filling (below): UNION_SITE_COUNTS (`mpileup -I -T union`, one task per sample) → JOINT_POOLED_LIKELIHOOD → GAP_FILLING step 1 (BC1, `dhd_bayes`) → LINE_UNION_COUNTS (per line, at the union sites) → GAP_FILLING step 2 (per-line ALT rescue, uses stage 4) → DONOR_FOUNDER (final donor allele per union site: ALT / REF / missing) | sample / donor set × chr | donor allele table (the final donor) |
| 7 | genotype | `genotype_imputation` | RASTERIZE: genotype = RTIGER ancestry × donor allele at every union site (NA where the ancestry is unknown, or the line carries the donor segment and the donor allele is missing). Optional: DONOR_FOUNDER gVCF (one reference block per lowcopy range, split at ALT records, no record at missing sites — §4 #11 → pseudo-assembly) → PHG_DATABASE → PHG_IMPUTATION (pairwise: B73 + donor, that donor's lines; F = 0, stay 0.99999) — §7 | donor × chr | genotypes at the union sites |
| 8 | genotype | `reporting` | CHROMOSOME_PAINTING (PHG no-call shown as no-call, not filled from the flanks), summary tables with the no-call share, KS / single-locus checks | donor × chr | paintings, tables |

### Mappability calibration (separate from both workflows; proposal, 2026-09-28)
**Not part of the CRAM or the genotype workflow** (user, 2026-09-28): a separate calibration whose only product used by the pipeline is the
per-taxon mappability prior, which the genotype workflow reads as a versioned reference input (like the B73 reference or the lowcopy
BED). Gap-filling step 2 sums out c, the share of a teosinte copy's reads that reach a B73 lowcopy site relative to B73's own reads, under
that prior. Today one prior (TIL18, chr10) serves every taxon, and it is estimated on the same simulation step 2 is validated on; the
calibration gives each taxon its own. It depends only on the founder assemblies/reads, the B73 reference and the aligner settings, so it
runs once, not per sample, and again only if the aligner or its settings change. It takes over steps 1 and 4 of zealbc1
`docs/PLAN_benchmark_calibration.md` (retention per founder; more founders).

**What exists (checked on hazel 2026-09-28):**

| taxon | founder | assembly (`/rsstu/users/r/rrellan/sara/ref/combined_genome/<taxon>/`) | real reads | aligned so far (QC set, chr10, kept at MAPQ 20) |
|---|---|---|---|---|
| B73 | reference | `ZEAL/reference/B73.fa` | ERR3288215 (15.5×, `results/b73_control/`) | simulated `B73_sim1–5`: 86 % |
| Zx | TIL18 | yes | — | simulated `TIL18_D`, `D2`: 43 % |
| Zd | Gigi | yes | — | simulated `Gigi_D`, `D2`: 34 % (not recorded in the zealbc1 plan) |
| Zv | TIL11 | yes | none in SRA | — |
| Zl | RIL003 | yes | SRR18441560, `ZEAL/raw/qc_set/RIL003/` (13.6 + 14.0 GB) | — |
| Zh | RIMHU001 | yes | SRR18441536, `ZEAL/raw/qc_set/RIMH001/` (13.1 + 13.4 GB) | — |

The zealbc1 notes record the two SRA downloads as cancelled on 2026-09-21 with a partial R1; both files are now present at sizes consistent
with ~23–24×, so they must be checked (read count against the SRA spot count) before use.

**Steps:**
1. **Check the downloads** (RIL003, RIMHU001): read counts vs SRA; R1/R2 pairing.
2. **Reads → alignment**, one Slurm array task per founder × chromosome (normal QOS; capped concurrency): simulated founders (Zx, Zd, Zv, and
   B73 as the baseline) — `wgsim` 2×150, QC-set error/insert settings, ~30× per assembly chromosome, streamed into minibwa `-x sr`
   against the whole B73 (stage 2 command; no FASTQ written; as zealbc1 `PHG/qcset/alignment_sim.sbatch`, which did chr10);
   real-read founders (Zl, Zh) — the real reads through the same alignment, compared with the real B73 reads (ERR3288215); their
   assemblies also give a simulated version, a check of simulated against real for the same founder.
3. **Count:** `bcftools mpileup -q 20 -Q 20` depth at every position of the lowcopy BED (the filters of discovery and gap filling); per site
   c = (founder depth / its nominal depth) ÷ (B73 depth / its nominal depth).
4. **Summarise and check:** per taxon, the c distribution on the step-2 grid (0–1.5) plus median and share below 0.25; optional per-site c
   table per taxon. Checks: within-taxon stability (a second assembly for at least one taxon, answering the circularity of estimating and
   validating on TIL18); between-taxon differences against divergence from B73; step 2's QC validation rerun with each taxon's own prior.
5. **Output** to the store, versioned by aligner version and settings: `calibration/mappability/<taxon>.prior.tsv` (and
   `<taxon>.per_site.tsv.gz` if kept); gap-filling step 2 reads the prior of each donor's taxon.

**Resources (to confirm on one test task — Zv, one chromosome — before the array):** ~6–7 genomes × 10 chromosomes ≈ 60–70 tasks, on the
order of 1–few hours each at ~30×; reads streamed, so disk is the per-chromosome CRAMs (a few GB each, removable after counting with the
user's consent) and the count tables; a few hundred files.

**Limitation:** a reference assembly is not the donor. The distribution-level prior is robust to that; a per-site table is only as good as
its within-taxon stability check.

### Stage 6 — two-step gap filling (decided, user, 2026-09-26)
A gap is a union site the donor did not discover itself; its own sites are ALT. Every gap goes through two steps, for every donor, before
the final donor (and anything built on it: raster, PHG) is made.
1. **Step 1 — BC1** (as in zealbc1 `PHG/bin/dhd_bayes.py`): the donor's BC1 reads at the gap, pooled LLR (math supplement Eq. S4.1):
   REF if LLR ≤ −4 and pooled depth ≥ 12; ALT if the posterior with the other donors' prior (Eq. S5.3) is ≥ 0.999; otherwise missing.
2. **Step 2 — per-line ALT rescue** (new), only at the sites step 1 left missing. The donor's BC2S3 lines are split by their RTIGER ancestry
   at the site: lines carrying the donor segment (x = 1, 2) and B73 lines (x = 0). A read from a donor copy shows the donor's base; B73
   copies show REF whatever the donor carries. Per line, with n reads and a ALT reads:
   - donor ALT: ALT fraction (x/2)·c / [(1 − x/2) + (x/2)·c] in donor-segment lines, ε in B73 lines; donor REF: ε in every line;
   - c = mappability of the donor copy relative to B73 at the site, summed out under a per-taxon prior (mexicana: from the QC-set TIL18
     pure donor reads vs B73 reads, median 0.85, 10.6 % of sites < 0.25); depth n ~ Pois(k_s · λ · [(1 − x/2) + (x/2)·c]), k_s from the
     B73 lines;
   - **the evidence adds (decided, user, 2026-09-28):** LLR_lines = log L(ALT) − log L(REF) from the lines, added to step 1's evidence:
     posterior(ALT) = σ( logit π + LLR_BC1 + LLR_lines ), π = the other-donor prior of Eq. S5.3; **call ALT at the same cut-off as step 1,
     ≥ 0.999; never REF.** One ALT read in a donor/donor line is ~1/ε ≈ 200 : 1 for ALT, while REF would need many donor-copy reads, and at
     a missing site there are ~0–1 (≈ 5 donor-segment lines of 40 at ~0.9x, donor copy mapping poorly). (Replaces a lines-only posterior
     ≥ 0.99, which was not derived; the 0.999 is the step-1 cut-off chosen 2026-09-23 from the QC per-site test by posterior bin.)
3. What is left stays **missing** (NA in the raster only for lines that carry the donor segment at the site).

**Evidence** (zealgt `agent/` scripts and `results/zealgt_checks/*_20260926/` on hazel; chr10):
- Missing after step 1, nb06 pilot: 11,819 (Zx.0540_P3) and 9,079 (Zx.0570_P2) gaps = 14.3 % and 11.0 % of the 82,840-allele union. Only
  3–4 % of them lack data; 85–88 % have ALT reads in BC1 that do not reach the cut-offs, at pooled depth 12–29.
- **Rejected: REF from the BC2S3 reads.** The merged witness pool added to the BC1 LLR turned QC-set holes into REF calls that were only
  29–44 % correct (bar: gap REF 97–98 %; job 963679): at those sites the donor reads map at ~1/5 of normal depth (6–8 vs ~40, job 963681), so
  "many reads, no ALT" is B73 reads showing B73. REF from donor-segment lines only has ~0–1 read per missing site.
- **Rejected: a false-allele hypothesis** (ALT reads independent of the ancestry at the site): its calls on the QC set were sites where the founder's own reads show ALT (truly ALT by the read-based truth) or unknown.
- **Step 2 validated** on the QC set (TIL18, 10 simulated lines at 0.8x and 1.2x, true and RTIGER ancestry; truth = what the founder's own
  simulated reads show at the site, §4 #14; jobs 967570, 967620):
  - at the 843 sites missing after step 1 (721 truly ALT, 0 truly REF, 122 unknown) the additive rule calls ALT at 189–243 sites per
    setting, all truly ALT or unknown (the earlier lines-only 0.99 rule: 122–220). With no truly-REF site in this set, precision here is
    not informative;
  - **specificity:** over all 29,098 truly-REF gap sites, **0 false ALT calls** in every setting, also with LLR_BC1 set to 0 (worst case);
    false-ALT rate < ~1 in 10,000 (95 % upper bound, rule of three);
  - sensitivity over the 11,918 truly-ALT gap sites: lines + prior alone 29 % (0.8x) and 46 % (1.2x); with the real LLR_BC1 93–94 %;
  - RTIGER ancestry performs as true ancestry. Bar = existing calls against the same truth: own ALT 99.9 %, gap ALT 100 %, gap REF 99.3 %.
- Pilot (real data, before duplicate marking, job 967570): step 2 calls ALT at 2,994 (Zx.0540_P3) and 2,581 (Zx.0570_P2) missing sites;
  founder missing falls to 10.7 % and 7.9 % of the union (8,825 and 6,498 sites). Of the earlier 0.99 calls, 2,233 and 2,145 are kept; the
  ~140–160 dropped per donor have BC1 evidence leaning REF.
- Caveat: the simulation has no PCR duplicates and reads from chr10 only; real error will be somewhat higher.

**To do:** write step 2 as a module (the additive rule; the tested code is `agent/20260928_001500_step2_combined.py`);
rerun steps 1–2 on the duplicate-marked CRAMs of the two pilot donors (duplicate marking: array job 963772,
`results/markdup_mexicana_20260927/`); per-taxon c priors come from the mappability calibration (separate from both workflows; a reference input).

### Stage 2b — sample QC before discovery (proposal, 2026-09-24)
Discovery assumes every BC1 sample and every line belongs to its recorded donor; a pollination error, seed mix-up or contaminated
pool breaks that silently (a wrong BC1 sample adds false alleles; a wrong line adds reads to the witness). The check must therefore run
before discovery and must not depend on any donor's discovered sites.
- **Blind QC panel:** lowcopy ranges ∩ teosinte-vs-B73 variants detected by wideseq, defined without any donor assumption. Positions only
  (panel genotypes are imputed). Caveat: distal taxa, huehuetenangensis most, are thin in the panels (1 Zh individual in Schnable 2023).
- **Minimum coverage (decided, user, 2026-09-27):** a sample with mean coverage **below 0.05×** (Picard CollectWgsMetrics
  `MEAN_COVERAGE`, after duplicate marking) is excluded from **all** processing — witness pool, discovery, ancestry inference, gap
  filling, genotypes — and listed in `sample_qc.tsv` with its coverage. Applied as soon as the CRAM workflow has produced the metrics, before any
  genotype-workflow stage. Batch 1 (1,437 skim samples, zealhmm `data/missing_data/wgs_per_sample.tsv`): 15 samples (1.0 %) fall below, 12 of them
  below 0.01× (8 below 0.001×, i.e. empty libraries), including PN6_SID484 (0.003×, the line RTIGER refused in the nb06 pilot); the other
  three are PN8_SID736 (0.011×), PN10_SID883 (0.030×) and PN11_SID979 (0.032×). Batch 2: not yet measured. (The sorghum PHG paper [5, Jensen
  et al. 2020] tested down to 0.01×; its 0.05 is a minor-allele-frequency filter, not a coverage cut-off, so 0.05× is a ZEAL choice.)
- **Coverage QC** (as in zealhmm `scripts/zeal_paired_cohort_coverage_qc.R`): covered panel markers per sample × chromosome; a line with
  any chromosome below 2 × rigidity covered markers is excluded from every caller (decided, §4 #13; as in zealhmm); the counts at 10 and 100
  are reported alongside. One table applied to every caller. λ per sample from CollectWgsMetrics alongside.
- **Relatedness QC:** lines (λ 0.05–1.6) from genotype likelihoods or one random read per site (pseudo-haploid), no hard calls; BC1
  samples from their per-site ALT fractions (correlation of centered frequency vectors). Centered kinship (VanRaden, as in zealhmm
  `zeal_mlm_taxon.R`); a sample is flagged when its kinship to its own donor's samples/lines falls outside the within-donor distribution,
  or when it is closer to another donor. Expected signal: lines are ~87.5% B73, so relatedness comes from teosinte alleles; same-donor
  lines share H_d segments.
- **Donor-content QC:** fraction of panel sites with ALT reads vs the 12.5% expectation — catches B73 contamination (selfing, seed mix),
  which kinship alone does not separate from a line that carries little donor genome.
- Flagged samples are excluded from discovery and from the witness; the table records why.
- Open: the relatedness method for mixed pool/line samples; flag thresholds; whether Zh needs its own panel (e.g. from its assembly).

Donor sets for stages 5–6 are named in a run card (`docs/runs/<run>.md`: purpose, donors with BC1 count / lines / coverage, exclusions),
and each entry checks the run card before starting.

### Teosinte reference variant space from the founder assemblies (plan, 2026-09-24; not yet in the math supplement)
How many sites differ between a teosinte haplotype and B73, per taxon, measured on the reference inbred assemblies rather than on reads.
Uses: the size of the variant space discovery works in, the truth allele set of the QC-set benchmark (PERFECT founder = assembly SNPs ∩
lowcopy BED), and annotation of step-4 tables.

**How it was done (zealbc1 chr10 PHG pilot, 2026-09-17; `agent/PHG_PILOT_chr10.md` step 4, `agent/pilot_1B_chr10_runlog_20260917.md`):**
founder assembly → AnchorWave against B73 v5, chr10 (run directly, not through `phg align-assemblies`) → MAF
(`ZEAL/results/phg_pilot/chr10/maf/`) → PHG `create-maf-vcf` → gVCF of the assembly vs B73 (`phg_pilot/chr10/vcf_files/<founder>.g.vcf.gz`)
→ SNP table `chr, pos, ref, alt` (`ZEAL/results/crisp_bench/<founder>_vs_B73_chr10_snps.tsv`). Only syntenic sequence aligned by
AnchorWave is counted.

| founder (taxon) | SNPs vs B73, chr10 | per chr10 length (~152 Mb) |
|---|---|---|
| TIL18 (mexicana) | 2,031,229 | ~1 / 75 bp |
| Gigi (diploperennis) | 2,090,083 | ~1 / 73 bp |

**In zealgt** (entry `reference_variant_space`, per founder × chromosome):
ANCHORWAVE_ALIGN (assembly vs B73 v5; ~1–2 h × 8 cpu per chromosome, ≤ 16 GB) → MAF_TO_GVCF (PHG `create-maf-vcf`) → ASSEMBLY_SNPS
(a tracked script: biallelic SNPs from the gVCF, `<NON_REF>`/reference blocks excluded, one row per site) → VARIANT_SPACE_SUMMARY
(per founder × chromosome: SNPs, aligned bp, SNPs per aligned kb and per chromosome Mb, SNPs inside the lowcopy BED).
1. **Reproduce first:** the gVCF → SNP-table step of 09-17 is not in any tracked script. ASSEMBLY_SNPS is written from scratch and
   run on the existing chr10 gVCFs; it must return exactly 2,031,229 (TIL18) and 2,090,083 (Gigi) before it is used anywhere else.
2. **Then the other founders:** TIL11 (parviglumis), RIL003 (luxurians; assembly is `.fa.gz`), RIMHU001 (huehuetenangensis) have
   assemblies but no alignment to B73 — one AnchorWave chr10 run each (also needed by the QC set, zealbc1 `docs/PLAN_benchmark_calibration.md`).
3. **Then genome-wide:** the remaining 9 chromosomes for all five founders (~400 CPU-h, the largest item; measure memory on one
   chromosome first).
Outputs go to the store (`ZEAL/store/reference_variants/`), not `work/`. The math supplement gets a text on this only after step 1.

## 4. Known issues and where each is settled
| # | issue (found 2026-09-20 → 24) | settled in | decision needed |
|---|---|---|---|
| 1 | No duplicate removal (BC1, lines, B73 pools). Pooled-caller benchmark and GATK best practices remove/mark PCR duplicates [1, 2]; CRISP paper silent [3] | stage 2 MARK_DUPLICATES | **decided 2026-09-24: `samtools markdup -d 2500`** (optical distance for NovaSeq patterned flow cells), in the alignment stream (`fixmate -m` → `sort` → `markdup`); imported nilhmm CRAMs: collate → fixmate → sort → markdup, same tool. Picard only if library-complexity metrics are wanted |
| 1b | No read groups: CRAMs lack @RG; a header-only RG made GATK count zero reads silently (09-21) | stage 2 | **decided 2026-09-24:** RG in every read, at alignment (`minibwa -R` if supported, else `samtools addreplacerg` inline before `fixmate`); imported CRAMs get it in the MARK_DUPLICATES pass. ID = sample (sample.lane if split), SM = Sample_Id, LB = library (BC1 pool / batch-2 row), PL = ILLUMINA, PU = flowcell.lane. Merged pools (witness) keep one RG. GATK is not used; if ever, the RG is already there. Fields that matter: **SM** (bcftools mpileup sample names) and **one RG per merged pool** (CRISP splits a file by RG). LB is written but no step depends on it: duplicate marking runs per sample CRAM (one library each), merged pools are not deduplicated |
| 2 | CRISP run with `--filterreads 0` (its mismatch filter off; the CRISP paper used ≤ 3 mismatches, MAPQ ≥ 20, base quality ≥ 17 [3]) | stage 3 CRISP | turn it back on? |
| 3 | Insertion records at a SNP position overwrite its counts (ALT → 0) unless `mpileup -I` | one COUNTS helper used by stages 3, 4, 6 | make the helper skip indel records itself |
| 4 | Demux QC table overwritten by every pool run (`results/demux_qc/demux_qc.tsv`; 09-24 the donors' rows had to be saved by hand to `bench_*/demux_qc_*_20260924.tsv`) | stage 1 DEMUX_QC | one file per pool (store) |
| 5 | Witness veto depends on witness depth (10 lines at 0.4x kept 20% of records) | stage 3 VETO | keep "≥ 1 ALT read" or make it depth-aware |
| 6 | Tiers depend on the count source (CRISP vs mpileup disagreed at ~15% of own tier-A sites) | stages 3 vs 6 | which counts define tiers |
| 7 | RTIGER rigidity fixed at 500 vs a density-scaled rule | stage 4 | confirm 500 |
| 8 | Marker union / donor allele calling / gap filling / ancestry inference exist only as standalone scripts (`PHG/bin/`) | stages 4–6 | port as modules |
| 9 | **CRISP reads the `--bed` end one base too far** (found and fixed in zealbc1 2026-09-24, zealbc1 `docs/DECISIONS.md`): it also calls the base right after every range; starts are read correctly (`variantcalls.c` tests `k >= start && k <= end` with raw BED values and a 0-based `k`; reported upstream as vibansal/crisp#34). Evidence: BED `chr10 105269 105270` (base 105,270 only) → CRISP reports 105,271; Zx.0570_P2 raw output has 29 records at range end + 1 (≈ the ~41 expected inside a range) vs 36 at range first bases; 18 of 82,724 rows of the Zx.0540_P3 + Zx.0570_P2 union sit 1 bp past a range end. Size ≤ 1 base per range (8,095 ranges, ~0.03% of the 26 Mb tested); sites inside ranges unaffected | stage 3, right after CRISP | **decided:** `bcftools view -T <lowcopy BED>` on the CRISP VCF before WITNESS_VETO, so step 4, the union and ancestry inference see only in-range sites (zealbc1 `PHG/bin/donor_discovery_chr10.sbatch`, dc95eea). Any zealbc1 table made before dc95eea carries the extra sites (step-4 tables of Zx.0540_P3, Zx.0570_P2, Zv.0490_P4, Zx.0150_P2, Zx.0100_P4, Zd.0040_P1, the QC-set founders, and every union / gap filling / founder / PHG / RTIGER output built on them); zealbc1 `PHG/qcset/variant_discovery.sbatch` is not fixed yet. Rerun with the fix: Zx.0540_P3, Zx.0570_P2 (jobs 949447, 949448; pre-fix outputs in `discovery/<donor>_preBEDfix/`) |
| 10 | nilHMM does not pass a design prior to RTIGER: the "BC2S3" and "BC2S2" RTIGER runs were byte-identical (zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §3.3) | stage 4 | **decided (user, 2026-09-24): run RTIGER as it has been run** (own tier-A sites, rigidity 500, parameters learned from the data); there is no design difference, so no BC2S2-vs-BC2S3 caller comparison |
| 11 | **A records-only union founder is unusable by PHG** (zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §3.2): `gvcf2hvcf` builds a haplotype only from stretches with gVCF records, so a records-only founder became joined 1–2 bp pieces (a 571-bp range → ~15 bp); 5,179 / 8,095 ranges had a founder haplotype and k-mer mapping gave zero TEO calls in all 44 Zx.0570_P2 lines (job 949013) | stage 7 (optional PHG founder) | **decided (user, 2026-09-24):** one reference block per lowcopy range, split at ALT records, no record at missing sites → every range has a full-length founder haplotype (B73 + the donor's ALT alleles; a missing site is the only absent base). Consequence: a range with no ALT site is identical to B73 and PHG reports it as no call |
| 12 | **Genotype frequencies are closer to the BC2S2 expectation, with HET excess and introgression deficit** (user, 2026-09-24; zealbc1 `docs/notebooks/06_fullcov_union_pilot_zx0540_zx0570.qmd` §2.4). chr10, RTIGER: HET 8.5–9.1 % vs 6.25 % (BC2S2) / 3.1 % (BC2S3), TEO 4.1–6.6 % vs 9.4 % / 10.9 %; PHG (share of called ranges): HET 10.2–11.2 %, TEO 1.9–2.4 %. TEO allele fraction 8.7–10.8 % (RTIGER), 7.0–8.0 % (PHG) vs 12.5 %. Both callers agree on which lines carry introgressions and where; PHG breaks RTIGER TEO segments into TEO/HET/B73 and calls recurring short HET spikes in lines RTIGER calls all B73 | reporting (single-locus checks); stage 7 | the bulks' parent is BC2S2 (user), so BC2S2 is the expectation in reporting; the HET excess and introgression deficit are reported against it. PHG shares are reported over called ranges with the no-call share (24–30 %), RTIGER over bp |
| 13 | One low-coverage line stops the whole RTIGER run: RTIGER refuses any line × chromosome with < 2 × rigidity covered markers; PN6_SID484 had 253 (floor 1,000) | stage 2b COVERAGE_QC | **decided (user, 2026-09-24): exclude the line as in zealhmm** (`scripts/zeal_paired_cohort_coverage_qc.R`): covered marker = site with ≥ 1 read; a line with any chromosome below 2 × rigidity covered markers is excluded from **every** caller (RTIGER, PHG, the rest), not only RTIGER, and listed in `sample_qc.tsv` with its per-chromosome counts. Markers = the sites ancestry inference uses (the donor's own tier-A sites; floor 1,000 at rigidity 500). The two failed development libraries are already excluded in `meta/dev_import.csv` |
| 14 | **The AnchorWave SNP list and minibwa-aligned reads from the same assembly disagree at ~27 K low-copy positions** (2026-09-26, job 963700; wording corrected 2026-09-28): the QC truth (`build_founder_gvcf/<F>_PERFECT.g.vcf.alt.tsv`) = AnchorWave SNPs ∩ lowcopy BED, and every other BED position is assumed REF. At the sites scored as false alleles (own tier A called ALT, truth REF: 16,350 Gigi, 11,151 TIL18), reads simulated from the same chr10 assembly (wgsim) and aligned with minibwa show a non-B73 base in ≥ 50 % of reads at 89–90 % of sites, at normal depth (38–39 vs 39–41 at true ALT sites); controls behave (true ALT 97–98 % ALT, true REF ≈ 1 %). No alignment is perfect: in repeats and around indels AnchorWave (collinear whole-genome alignment) and minibwa (short reads) place sequence by their own heuristics, and the data cannot say which gets the homology right. Leading explanation (user, 2026-09-28): **false alleles** — the ALT reads come from another copy in the donor (duplication / paralogous stretch) that minibwa maps to a B73 position whose syntenic donor base is REF in the AnchorWave alignment; normal depth does not rule this out (the syntenic donor copy maps poorly and the other copy takes its place). When that copy sits in the same donor segment, its reads co-segregate with the donor ancestry at the site in BC1, witness and lines, so no read-based test separates it from a real allele; only a high-quality donor assembly or long reads can. Consequences: acceptable for mapping (the allele marks the right segment), not for allele-level claims (which base the donor carries at a gene); the read-based benchmark measures reproduction of the donor's reads and cannot measure this error, which must be said when precision is reported; the B73-check filter and the per-line test cannot remove it (they catch stock artifacts and copies in other segments only). Other possible causes: positions AnchorWave does not align (REF by default), or SNPs dropped by the untracked MAF → SNP extraction. Testable in the QC set, where the source of every simulated read is known (proposed hypothesis test, §7). Against the read-based truth, discovery precision is ≈ 96.5 % / 97 % (own tier A) and ≈ 99 % (gap ALT) instead of 68–74 % | benchmarking (QC set) and the reference variant space (§3) | score the QC set against the founder's own minibwa-aligned reads: the pipeline genotypes from minibwa-aligned reads, so that is the right reference **for the read-based steps** (not a better truth about homology); for the reference variant space, a truth with three states per position (ALT / REF where aligned / unknown where unaligned); find the cause on a sample of sites in the MAF |

## 5. Storage, caching and cleanup (from the disk audit, 2026-09-24, job 946049)
Measured (`du -sk` / `--inodes`, one array task per directory; table `ZEAL/results/audit_du_20260924/tasks/`):

| location | size | files |
|---|---|---|
| `results/work/` (Nextflow, `--outdir ZEAL/results` runs) | 1,903 GB | 1,482 |
| `results/gate2/work/` | 1,015 GB | 1,064 |
| `results/bc2s3_batch2/work/` | 279 GB | 2,047 |
| `results/demux/` | 81 GB | 37 |
| `ZEAL/reference/` | 65 GB | 263 |
| `results/align_membench/` (pool-1B CRAMs) | 41 GB | 25 |
| `results/cram/` | 22 GB | 21 |
| `results/b73_control/` | 22 GB | 26 |
| `/share/maize/frodrig4/tmp` | 22 GB | 652 |
| `results/qcset_designB/`, `results/pilot_1B_chr10/` | 17 GB, 16 GB | 5.6K, 6.0K |
| `ZEAL/envs/`, `/share/maize/frodrig4/conda` | 15 GB, 12 GB | 49K, 160K |
| all other `results/*` (pilots, benchmarks, logs, PHG DBs 0.2–1.2 GB each) | < 10 GB each | |
| `results/stub/` | 0.3 GB | 106K |

Findings: ~3.2 of ~3.6 TB is Nextflow `work/` (few, huge files: demux FASTQs + alignment intermediates of the pool, gate-2 and
batch-2 runs), because `nextflow.config` sets `workDir = "${params.outdir}/work"` on the persistent partition. Published results are
small. The large file counts are environments and the stub run, not data.

**Scratch quota (measured 2026-09-27, `mmlsquota -g maize gpfsHPCcommon2`; corrects the earlier "2 TB").** `/share/maize` is on GPFS
(`/gpfs_common`, device `gpfsHPCcommon2`, fileset Share01) under a **group** quota for `maize`, shared with the whole lab: **space 20 TB**
(326 GB used) and **1,000,000 files** (775,811 used, 78 %; ~224 K left). No user quota is enabled. `/share/maize/frodrig4` holds 41 GB. Space is
ample; the **file count is the binding limit**, and reaching it blocks writes for the whole group.

**CRAM-workflow disk budget (estimated 2026-09-27, `agent/20260927_214500_raw_sizes.sh`).** Raw inputs (read-only, stay in place): BC1 32 libraries
4.97 TB (80–362 GB each; largest 4E 362, 1C 295, 1D 280, 1Ar 252), BC2S3 batch 2 0.57 TB, batch-1 tars 1.52 TB — ≈ 7.1 TB (plus 0.51 TB
BC1 `Undetermined`, not processed). Store (duplicate-marked CRAMs without MAPQ filter + QC): ≈ 1.8–2.1 TB on `/rsstu` (pilot BC1 CRAMs are
≈ 0.2 × raw with the MAPQ-20 filter; 0.25–0.30 assumed without it). Scratch peak ≈ 1.1 × library per DEMUX+ALIGN task: ≈ 0.6 TB for 4 typical
libraries at once, ≈ 1.3–1.5 TB if the 4 largest run together. Persistent partition: 16 TB free (≈ 19 TB after the old `work/` is removed).

Rules for v2:
1. `workDir` **and** the task temp (`TMPDIR`, sort temp) on `/share/maize/frodrig4/nf_work/<run>` (GPFS scratch, not persistent), not on
   `/rsstu` (NFS: slower for demux/sort I/O, and persistent `work/` is how the 3.2 TB accumulated). Results published to `/rsstu`.
2. CRAMs, per-library demux QC, provenance, registry and (genotype workflow, not built yet) step-4 tables in the store on `/rsstu`
   (`ZEAL/store/{cram,cram_import,demux_qc,registry,step4,…}`), never in `work/`: written by `publishDir` (`mode: 'copy'`, since `/rsstu` is another filesystem; `overwrite: false`;
   `failOnError: true`), and reused by explicit skip-if-stored logic in the workflow instead of `storeDir` (2026-09-28, §2 principle 3):
   CRAMs per sample (`read_alignment` and `markdup_import`), demux QC per library, provenance per sample, registry per library. A CRAM
   is stored only if CRAM + `.crai` exist and the CRAM ends with the CRAM 3 EOF container; a present but unverified CRAM is an error that
   names the file, never overwritten. Each module's `versions.yml` stays next to its CRAM, so the provenance of an already stored CRAM
   can be written without rerunning it.
3. Demux FASTQs never outlive their library's stage 1 in `work/`: DEMUX (per lane) → MERGE_LANES → CUTADAPT pass FASTQs through
   `work/` (§0, Task 2, user 2026-09-27), and each sample's trimmed pair is **hardlinked into the FASTQ checkpoint**
   `/share/maize/frodrig4/fastq_checkpoint/<library>/` (user, 2026-09-29; §3). **Checkpoint footprint ≈ N libraries × 0.83 ×
   raw** (cutadapt level-4 trimmed pairs, measured 2026-09-29: BC1 120-125 B per kept pair = 0.83 × raw, 0.855 × the demux
   FASTQs, `simplify_g1l4` and the compression retest; batch 1 ~145 B per pair ≈ 0.82 × raw, estimated from `simplify_b1g1`
   at level 1; +9 % over Trimmomatic's 0.76 × raw at 3A; full 1A ≈ 210 GB; `docs/REQUIREMENTS.md` §4), and hardlinked, so while `work/` holds the same file it costs
   **no extra space and no extra inode**; once `work/` is cleaned the checkpoint alone holds those bytes (the space moves, it does not
   grow). Files: 2 per sample + `samplesheet.csv` + `cleanup_status.tsv` (≈ 26 per 12-sample library), negligible against the group
   quota (12 samples: 38 files, ~110 GB for a typical 130 GB BC1 library; a 96-sample batch-1 plate: 290 files, 50-75 GB).
   The checkpoint must stay on the same GPFS as `work/` (a hardlink cannot cross `/share` → `/rsstu`).
   **At most N libraries hold FASTQs on `/share`** (user, 2026-09-29, replacing "one library in flight", which rested on the wrong
   2 TB scratch figure — the group has 20 TB, and the file count is the binding limit; bound as a run guard, coordinator 2026-09-28).
   Nothing is removed automatically: `work/` keeps every library of a run for the whole run (and after it, until cleaned with
   consent), and the checkpoint keeps each library's trimmed pairs until the user removes them (rule 4). A concurrency limit alone
   would therefore not bound the disk: the in-run admission semaphore tried on 2026-09-28 (Phase B: at most N libraries in stage 1
   at a time, the next admitted when one finished) was **rejected** for that reason — under the no-auto-delete rule a finished
   library keeps its `work/` FASTQs and its checkpoint until the user cleans them, so a semaphore bounds how many libraries are
   *processed* at once, not how many *hold FASTQs*; a 32-library request would still leave 32 libraries on `/share` (and it
   relied on one blocking operator on Nextflow's fixed dataflow pool). So `--max_libraries N` (default 4) bounds what a run may hold: `read_demultiplexing` is
   **refused** when |requested libraries ∪ libraries that already have a checkpoint dir under `--fastq_checkpoint`| > N (`subsample_*`
   and `checkpoint_stub*` dirs are other checkpoint roots and not counted); the error names those libraries and their
   `cleanup_status.tsv`, whose checkpoint may be removed only with the user's consent. The requested libraries then all run
   concurrently: **no `maxForks`** on DEMUX or any other process (at most N × lanes DEMUX tasks), the queue sets the wall time.
   `read_alignment` adds no library (it reads existing checkpoints). Each library holds ≈ 3 × its raw size in `work/` at peak (lane
   demux FASTQs 0.95 + merged copy 0.95 + trimmed 0.83 + CRAMs 0.29; Gate 2 3A measured 2.72 × raw with Trimmomatic) and
   ~1.3 K files for a BC1 library (+39 per lane beyond 3), ~7.1 K for a 96-sample batch-1 plate, so N is set so that the peak
   stays under ~5 TB of `/share` and the group stays under 90 % of its file quota (default N = 4: ≈ 1.4 TB for CRAM Gate 2's
   largest wave, w02 = 2B 2H 3C BZea6; ≈ 3.6 TB for the 4 largest BC1 libraries 4E, 1C, 1D, 1Ar; checkpoint 0.39 / 0.99 TB). The guard sees only
   checkpoint dirs, not the `work/` of earlier runs: those are cleaned after each run (rule 4). A chained run's stage 2 reads
   CUTADAPT's `work/` files, not the checkpoint, so a library's stage-1 task dirs can be cleaned (with consent) only **after the
   run has ended** — then `read_alignment` reads the checkpoint, and a `-resume` of that session would redo stage 1. Cleaning them
   frees no space while the checkpoint holds the hardlinked pairs (the space moves to the checkpoint), only the demux FASTQs.
   More than N libraries (Gate 3) therefore run as **waves** of ≤ N libraries, one run each, with the user's consented cleanup
   of the finished wave's checkpoint and `work/` (rule 4's cleanup file) between two waves (§6).
4. **Cleanup.** The pipeline never removes anything. A library's checkpoint FASTQs are removed **only after all its CRAMs are stored and
   verified** (rule 2), and **only with the user's consent** (`CLAUDE.md`): every run with stage 2 (chained or alone) reports it per
   library in the log and in `<checkpoint>/<library>/cleanup_status.tsv` (tab-separated `sample cram cram_bytes verified fastq_1
   fastq_1_bytes fastq_2 fastq_2_bytes`, one row per sample; verified = CRAM + `.crai` + CRAM 3 EOF), ending in `# checkpoint <dir>:
   removable (N files, X GB) — remove only with the user's consent` (N counts the FASTQs) or `# checkpoint <dir>: keep: k of n CRAMs
   missing`. Removing a checkpoint dir is also what lets `--max_libraries` admit new libraries (rule 3). The same run writes
   **`<outdir>/pipeline_info/cleanup_<run_id or session>.sh`** (also printed in the log), which the pipeline never runs: a header
   saying so and that it must be read before use; per removable library, listing / measuring commands (`ls`, `du`, `find
   -maxdepth … | wc -l`, `cat cleanup_status.tsv`) for its checkpoint dir and for the run's `work/` task dirs that hold its FASTQs
   (DEMUX, MERGE_LANES, CUTADAPT, FASTQC; path, size, file count, hardlinked bytes, measured by the pipeline at the end of the
   run, depth-bounded), then the removal lines commented out under `# CONSENT:`; per library that is not complete, `keep: k of n
   CRAMs missing` and no removal line; and, when every library of the run is removable, a `nextflow clean -n` / `-f <run name>`
   alternative for the whole run's `work/` (never the checkpoint). The task dirs are taken from those processes' output channels
   (each output's `<workDir>/xx/hash` dir; cached tasks included; failed or retried attempts are left to `nextflow clean`), not
   from the trace file (no library there, hash prefix only, still being written in `onComplete`). After each run: the user checks
   the file and removes, with consent, what it lists (stub runs always cleaned), and a size **and file-count** report.
5. Existing `work/` (3.2 TB): before deleting, confirm every CRAM / table the project uses is published outside `work/`
   (`results/cram`, `results/align_membench`, `results/bc2s3_batch2/cram`, the pilot dirs) — decision and check pending, nothing deleted.
   `results/work/` and `results/bc2s3_batch2/work/` hold the only copy of the demuxed reads of ~130 BC1 samples and ~185 batch-2 lines (§0,
   Task 1); `results/gate2/work/` (pool 1B, all 12 samples aligned in `results/align_membench`) can go now.
6. **File budget:** the conda environments **stay on `/share`** in `/share/maize/frodrig4/conda/zealgt` (user rule: never moved,
   rebuilt or deleted; `/rsstu` is too slow for them, §2 principle 6). They count against the group's file quota
   (`/share/maize/frodrig4/conda` held ~160 K files at the 09-24 audit), so the file budget is kept by
   the runs: a run whose work directory would exceed ~50 K files is split or cleaned between runs (with consent).

## 6. Supervision
Per run: own launch dir and `workDir`; a post-run check (work size, failed tasks, published outputs); monitors, not sleep loops; long runs
watched with the session kept open (`/loop`), acting only as the run card allows.

### Testing ladder (gates, from zealbc1; climb only when the current gate passes)
The ladder is climbed per workflow, in this order (user, 2026-09-29): the CRAM workflow's minimal gates → CRAM Gate 2 on the genotype
development donors' libraries → the genotype workflow's Gate 1 / Gate 2 on those CRAMs → the full dataset in waves on the user's go.
- **Gate −1 · CodeRabbit** (user rule, 2026-09-29): `coderabbit review --committed --base-commit <last reviewed> --agent` must pass on
  the exact commit before any **costly** run (Gate 2 and up, full libraries, production, > ~20 CPU-h); cheap diagnostics (Gate 0/1,
  subsample tests) do not wait. Scope: only code that executes (modules, subworkflows, workflows, conf, nextflow.config, templates,
  bin, scripts, tests) — not agent/ scratch, docs or meta data. It catches code/API bugs, not environment/data bugs; every finding is
  checked against the code before it is applied.
- **CRAM workflow, minimal gates** (short QOS):
  - **Gate 0 · `-stub-run`**: every module's `stub:` touches its outputs, so the whole DAG runs in seconds and proves wiring,
    channel joins and filenames. Stub `work/` is cleaned afterwards (§5 rule 4, with the user's consent).
  - **Gate 1 · subsample through the full code path**: real tools on `--subsample N` of one library (store and checkpoint named
    `subsample_<N>`). **The small run must go through the same code path as the full run** (lesson of 2026-09-28: `--subsample`
    wrote real files while the full run streamed lanes through pipes, so the pipe failure first appeared at a full library): the
    subset option only limits the amount of data, never switches the I/O code; run it with the full-run thread counts on Slurm (the
    local test profile's 1 CPU hid a `-j > 1` failure), and cover every input layout the full run meets (several lanes, batch-1 tar
    members).
  - **Cache tests**: `scripts/test_cache.sh` on the laptop and at Gate 1 scale on hazel (`scripts/test_cache.sbatch`), RESULT:
    PASSED (below, "Test cache behaviour").
  - **Memory test**: the ALIGN_MARKDUP / MARKDUP_IMPORT memory model (`docs/REQUIREMENTS.md` §4) holds at full depth — the largest
    samples of the Gate 2 set, under the production memory settings, peak RSS below 0.95 × the request on the first attempt — and
    `scripts/check_resources.sh` passes for what every process requests.
- **CRAM Gate 2 · the genotype development donors at full depth, into the production store** (`-profile hazel,normal`, the
  benchmark: cpu/ram/time/disk per module into `docs/REQUIREMENTS.md`). The libraries holding the two development donors
  (`meta/registry.csv`, `donor_resolved`):
  - BC1 **2A, 2B, 2F** (Zx.0540_P3) and **2H, 3B, 3C, 3D, 3E** (Zx.0570_P2), each named in `--force_demux` (they are in the
    registry seed);
  - the batch-1 plates holding those donors' lines: **BZea5, BZea6** (Zx.0540_P3, 15 + 25 samples) and **BZea8, BZea9**
    (Zx.0570_P2, 34 + 10 samples), whole plates (a library is demultiplexed once, all its samples);
  - the B73 controls **B73_ERR3288215** and **B73_skim10** through `--entry markdup_import --import_sets b73_control`.
  `read_demultiplexing` in waves of 4 libraries (three waves for the 12 libraries, each with its own `--run_id`, as Gate 3
  below). The FASTQ checkpoint of these libraries is **kept** (no consented cleanup of them) until the genotype workflow's Gate 2
  passes, so a CRAM-side fix found there reruns only stage 2 (`--entry read_alignment`). The run guard counts the checkpoint dirs
  already present, so with the checkpoints kept wave k passes `--max_libraries 4k` (4, 8, 12): 4 libraries run at a time, and the
  bound says explicitly how many libraries' FASTQs are then held on `/share` (≈ 0.83 × raw each, §5: 0.36 / 0.75 / 1.05 TB after waves
  w01-w03 of `docs/runs/cram_gate2_w0{1,2,3}.md`; user 2026-09-29: keep the checkpoints, `--max_libraries` 4 / 8 / 12). The stage-1 `work/` of a wave
  may still be cleaned with consent (the checkpoint files are hardlinks and stay).
- **Genotype workflow Gate 1 / Gate 2** on those CRAMs (genotype session's gates; Gate 2 = the development donors in full).
- **Gate 3 · full dataset in waves, on the user's go**, once the Gate 2 numbers justify the allocation. CRAM workflow: **waves** of ≤ `--max_libraries` libraries,
  one `read_demultiplexing` run (own `--run_id`) per wave (§5 rule 3). Between two waves: the wave's head job has ended, its log
  shows no failed task, and the user — after reading `<outdir>/pipeline_info/cleanup_<run_id>.sh` and running its listing lines —
  consents to removing the finished (removable) libraries' checkpoint dirs and the wave's `work/` (the file's commented `rm` lines,
  or its `nextflow clean` alternative when every library is removable); `keep` libraries are rerun first. Only then the next
  wave, whose guard counts the checkpoint dirs still present. Not a semaphore inside one big run: it would bound concurrency,
  not the FASTQs held on `/share`, because nothing is removed automatically (§5 rule 3). Operator steps: docs/usage.md
  "Waves of libraries".

Lessons turned into checks (2026-09-28):
- **Check the resolved resources, not the config text.** At Gate 2, TRIMMOMATIC's own `withName: 'TRIMMOMATIC' { time = 12.h }` in
  `conf/normal.config` silently lost to the combined `DEMUX|TRIMMOMATIC|…` selector, so 4 h applied (enough: 25–31 k pairs/s; the dead
  block is removed). `scripts/check_resources.sh` stub-runs the real profiles (`hazel,normal` and `hazel,short`) on the local executor
  and compares each process's traced `cpus`, `memory`, `time` and `queue` with `tests/expected_resources.tsv` (one row per profile ×
  process; a new process or a resource change needs a row update); it caught the old precedence loss when fed the old intent. Part of
  `scripts/run_checks.sh` (full mode), with `scripts/check_ext_args.py` (§2 principle 4) in every mode.
- **Test cache behaviour on the pinned Nextflow, do not assume it.** The hash test (job 972453) overturned the old §2 table and with it
  the reason for the Slurm resource helper. A cache test (`scripts/test_cache.sh`, an operator script, not an nf-test: nf-test cannot
  share one Nextflow session across runs — a deliberate deviation recorded in `.nf-core.yml` and `docs/usage.md`) proves in one launch dir: (a) a resume with raised cpus / memory / time keeps every task cached; (b) after an
  ALIGN_MARKDUP script edit, with a fresh store, stage 1 stays cached and only ALIGN_MARKDUP and its downstream rerun; (c)
  `read_alignment` alone runs only stage-2 tasks from the checkpoint. It prints each task's hash per run (`-dump-hashes json`); run
  on the laptop and at Gate 1 scale on hazel before a gate that depends on reuse. First finding (2026-09-28): PROVENANCE reran on
  every resume because its hashed record carried the Nextflow run name; the name was dropped from the record, and (a) is now
  strict (laptop: PASSED, 24 of 24 cached).
- **Bound what is held, not what runs.** Under the no-auto-delete rule a library's FASTQs stay on `/share` after it finishes, so
  an admission semaphore (at most N libraries in stage 1 at once) let a long request hold every library's FASTQs; it was replaced
  by the `--max_libraries` run guard plus waves with a consented cleanup between them, and each run now prints the exact cleanup
  commands (never runs them) so the between-wave step is a check of listed paths, not a hunt through `work/`.

## 7. Open decisions (summary)
§4 #2, #3, #5–#7, #12, #14 (proposed test: in the QC set, trace each ALT read at the disputed sites to its source position in the
assembly — wgsim records it in the read name — and compare with the AnchorWave-mapped syntenic position; syntenic source = alignment/
extraction gap, source elsewhere = false allele, with the distance telling linked vs unlinked copies); storage rules of §5; which existing CRAMs and tables are reused vs regenerated after MARKDUP.
Stage 7: PHG or the RTIGER × donor-allele raster for the GWAS matrix. Without donor assemblies the PHG donor haplotype is B73 plus the
discovered SNPs, the same information the raster uses, judged per reference range with few reads (nb06: 24–30 % of ranges no-call, TEO
segments broken into HET/B73; PHG has no mapping-bias term, `find-paths --prob-correct` is the same for every haplotype); RTIGER pools
evidence over long runs of markers (~99 % of chr10 × lines). Leaning (user, 2026-09-26): the raster supersedes PHG.

## References
1. Huang HW, Mullikin JC, Hansen NF. Evaluation of variant detection software for pooled next-generation sequence data.
   *BMC Bioinformatics* 2015;16:235. doi:10.1186/s12859-015-0624-y
2. Van der Auwera GA, Carneiro MO, Hartl C, Poplin R, et al. From FastQ data to high-confidence variant calls: the Genome Analysis
   Toolkit best practices pipeline. *Curr Protoc Bioinformatics* 2013;43:11.10.1–11.10.33. doi:10.1002/0471250953.bi1110s43
3. Bansal V. A statistical method for the detection of variants from next-generation resequencing of DNA pools.
   *Bioinformatics* 2010;26(12):i318–i324. PMC2881398
4. Danecek P, et al. Twelve years of SAMtools and BCFtools. *GigaScience* 2021;10(2):giab008. (not re-checked this session)
5. Jensen SE, Charles JR, Muleta K, et al. A sorghum practical haplotype graph facilitates genome-wide imputation and cost-effective
   genomic prediction. *Plant Genome* 2020;13(1):e20009. doi:10.1002/tpg2.20009 (full text read 2026-09-26, PMC12807297)
