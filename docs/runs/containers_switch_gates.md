# Run card: the container switch on the plain hazel profiles (Gate 0 all entries, Gate 1 both workflows)

**Purpose.** docs/PLAN_containers.md §5 step 5, the switch's test before the PR: `-profile hazel` is Apptainer now (no
`apptainer_hazel` profile), every template logs to stderr (Python `logging` / R `logger`), CHROMOSOME_PAINTING and RTIGER
have new images (r-logger), and `--input` is no longer validated at start-up. Show that every entry runs on the plain
profiles and that the logging changed no output: both Gate 1 runs are compared byte for byte with the step-4 container
runs (same images apart from the two new ones). A bug check (Gate 0/1 judge bugs, not accuracy). Nothing goes into
`ZEAL/store`; `ZEAL/store_genotype_dev` is read only.

**Code.** Hazel checkout `ZEAL/zealgt-containers`, branch `containers` @ b0e83b1 or the commit that adds this card (`ZG_REPO`).
Baselines, **not rerun**: CRAM `containers_g1` (job 1000446, code a6868e3, `nf_work/containers_g1/`); genotype key
`gate1_mex2_containers_r2` (jobs 1002943-1002949, code ffcbf01, `nf_work/containers_geno_g1/store`).

**Before the runs (step 5 on hazel).** `git pull`; download the two new images into `/share/maize/frodrig4/apptainer/cache`:
CHROMOSOME_PAINTING's Seqera SIF (curl, as `agent/20260930_160500_download_sifs.sbatch`) and
`ghcr.io/sawers-rellan-labs/zealgt-nilhmm:0.3.1-1` (`apptainer pull --disable-cache`, as
`agent/20260930_163500_pull_ghcr_sifs.sbatch`, after its GitHub Actions build succeeds); inside each, check the module's
commands and `Rscript -e 'library(logger)'` (short QOS job).

**Runs** (head jobs `scripts/submit_head_job.sbatch`, short QOS; run dirs under `/share/maize/frodrig4/nf_work/`):

| run_id | profile | entry / params | store / key |
|---|---|---|---|
| `switch_cram_g0_demux` | `hazel,stub` `-stub` | read_demultiplexing, 1A (chains into stage 2) | the run's `store_stub` |
| `switch_cram_g0_import` | `hazel,stub` `-stub` | markdup_import, `--import_sheet docs/runs/gate0/cram_gate0_import.csv` | the run's `store_stub` |
| `switch_geno_g0_<entry>` x 7 | `hazel,stub` `-stub` | `docs/runs/gate0/genotype_gate0_<entry>.yml` | `nf_work/switch_geno_g0/store_stub`, key `switch_g0` |
| `switch_cram_g1` | `hazel,short` | read_demultiplexing, 1A, `--force_demux 1A --subsample 1000000` | the run's own store / checkpoint |
| `switch_geno_g1_<entry>` x 7 | `hazel,short` | `docs/runs/genotype_gate1_mex2.yml` | `nf_work/switch_geno_g1/store`, key `gate1_mex2_switch_r1` |

The genotype chains run one head job per entry in stage order (`--dependency=afterok`;
`agent/20260930_171500_submit_genotype_chain.sh` with `apptainer_hazel` dropped from its profile strings). Both Gate 1s
start after every Gate 0 succeeds, and run at the same time.

**Gate 0 import sheet.** `docs/runs/gate0/cram_gate0_import.csv`: 3 rows of `meta/dev_import.csv` covering the input
kinds (B73_skim10, a BAM; PN5_SID464, a BC2S3 line CRAM; S_2A_11, a BC1 CRAM), ≈ 12 stub tasks, ≈ 2 min. Added after the
first run of this card (2026-09-30, job 1004870) used the default sheet: 96 CRAMs x 4 processes ≈ 372 Slurm jobs of
instant stub tasks, ≈ 25 min of submission and polling. Never run a Gate 0 stub on the full dev sheet.

**Cost.** Gate 0: a few minutes per entry. CRAM Gate 1 ≈ 26 min (`containers_g1`: 25:51); genotype Gate 1 ≈ 21 min (`_r2`).

**Done means.**
1. Gate 0, 9 runs: SUCCESS; every task via `apptainer exec`; 0 "Creating env", 0 pulls in the `.nextflow.log`s.
2. CRAM Gate 1: SUCCESS, the same 79 tasks in 11 processes as `containers_g1`; per CRAM the alignment records
   (`samtools view -T B73.fa`, md5) identical; demux QC (`demux_qc`), registry, Picard and samtools stats tables
   identical apart from run dates and paths; the CRAMs byte-identical (same images, so even the compression should match).
   This is the only run that executes the new `demux_qc` and `registry` templates.
3. Genotype Gate 1: all 7 SUCCESS, task counts per process equal to `_r2`; every file under the new key byte-identical
   to `_r2`, except files known to embed a run value (`settings/*.json`: key, session, module code hashes; the step-4
   `sites.tsv.gz`: gzip's write time, compared after decompression). RTIGER segments and genotype calls identical. Only
   this run's traces count (the comparison script `agent/20260930_183000_compare_genotype_gate1.sbatch`, pointed at the
   new key).
4. Logging: in each Gate 1, every template task's `.command.err` has timestamped `[<process>]` lines; a task running
   longer than a minute shows `>>> ... ETA` progress lines about once a minute. Nothing the logging writes is in an output.
5. Measured: time and peak memory per process vs the baselines (no process meaningfully higher).

Any difference in 2 or 3 is investigated before the PR.

**Afterwards.** Nothing is removed without consent; the run dirs `nf_work/switch_*` and the head-job dirs are listed for
cleanup 1 (docs/PLAN_cleanup.md) once the comparison is written up in docs/PLAN_containers.md §7.
