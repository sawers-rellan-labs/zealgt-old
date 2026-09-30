# Run card: containers Gate 0 + Gate 1, CRAM workflow, library 1A (Apptainer vs conda)

**Purpose.** docs/PLAN_containers.md §5 step 4 for the CRAM workflow: show that `-profile hazel,apptainer_hazel` runs every
CRAM-workflow process from its image (no conda, offline compute nodes) and gives the same outputs as conda on the same
input. A bug check (Gate 0/1 judge bugs, not accuracy), not a production run: nothing goes into `ZEAL/store`.

**Code.** Containers: hazel checkout `ZEAL/zealgt-containers`, branch `containers` @ 76e5547 (`ZG_REPO`). Conda baseline:
`ZEAL/zealgt`, `main` @ d3b6eb1 (the previous conda baseline `simplify_g1l4` was cleaned from `nf_work`, so it is rerun).
The two differ only in the container work (profile, container lines, environment.yml build strings, Dockerfiles).

**Selection.** Library **1A** (`--force_demux 1A`), as every earlier CRAM gate; Gate 1 at `--subsample 1000000`
(1,000,000 read pairs per lane), the size of `simplify_g1l4`. No exclusions.

**Runs** (all head jobs `scripts/submit_head_job.sbatch`, short QOS; work, store, checkpoint and results under
`/share/maize/frodrig4/nf_work/<run_id>/`):

| run_id | checkout | profile | entry / size |
|---|---|---|---|
| `containers_g0` | zealgt-containers | `hazel,apptainer_hazel,stub` `-stub` | read_demultiplexing, 1A (stub) |
| `containers_g1` | zealgt-containers | `hazel,apptainer_hazel,short` | read_demultiplexing, 1A, `--subsample 1000000` |
| `conda_g1` | zealgt (main) | `hazel,short` | read_demultiplexing, 1A, `--subsample 1000000` |

`containers_g1` and `conda_g1` run at the same time, after `containers_g0` succeeds.

**Inputs.** `meta/samples.csv` rows of 1A (raw FASTQs on `/rsstu`), `ZEAL/reference/B73.fa`. Images: the 15 public SIFs in
`/share/maize/frodrig4/apptainer/cache` (job 999636). CRISP / nilHMM are not used by the CRAM workflow.

**Done means.**
1. `containers_g0`: SUCCESS; every task ran in a container (`.command.run` calls `apptainer exec`); no "Creating env" and
   no image pull in `.nextflow.log` (the cached SIF names match what Nextflow looks for).
2. `containers_g1` and `conda_g1`: both SUCCESS with the same task counts.
3. Same outputs: per CRAM the alignment records (`samtools view`, no header) identical in md5; demux QC, samtools stats and
   Picard WGS metrics tables identical except run dates and paths; the reported tool versions equal (both use the same
   versions; builds may differ).
4. Measured: task time and memory per process (trace `peak_rss`, `sacct MaxRSS`) for both, noted in docs/PLAN_containers.md;
   a process whose container peak is meaningfully higher gets a memory margin before Gate 2 (hazel kills at 95 % of `--mem`).
5. Image mount mode on a compute node (kernel squashfs via loop device, or a squashfuse helper process inside the job,
   whose memory counts toward the task's cgroup): read from inside a container (`/proc/mounts`) and the host side
   (`apptainer buildcfg`, `ps` during an exec); added 2026-09-30 (user).

Any difference in 3 is investigated before the switch (step 5).

**Afterwards.** Nothing is removed without consent; the three run dirs are listed for cleanup once the comparison is written up.
