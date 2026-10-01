#!/bin/bash
# scripts/submit_head_job.sbatch — the Nextflow head job of a zealgt run on hazel (never the login node; hazel-debug-loop skill).
#
#   sbatch scripts/submit_head_job.sbatch <run_id> <nextflow run args ...>
#   e.g. sbatch scripts/submit_head_job.sbatch gate0_demux -profile hazel,stub -stub --entry read_demultiplexing --libraries 1A \
#            --force_demux 1A --outdir /rsstu/users/r/rrellan/BZea/ZEAL/results/zealgt/gate0_demux
#   Multi-library / production runs (-profile hazel,normal; a BC1 wave of 4 libraries is ~13 h compute + queue waits):
#       sbatch --qos=normal --partition=compute --time=3-00:00:00 scripts/submit_head_job.sbatch <run_id> -profile hazel,normal ...
#   (sbatch command-line options override the #SBATCH lines below; normal QOS allows up to 4 days). The head only submits and
#   polls, and each task job's own QOS comes from conf/normal.config (short or normal per task), not from the head's.
#
# Default (gates): 1 cpu, 8 GB (zealbc1 heads peaked at 3.8 of 4 GB; Gate 2 0.42 GB), short QOS, 2 h. Launch directory (.nextflow/, .nextflow.log, history)
# = /share/maize/frodrig4/nf_work/<run_id>/launch; workDir and TMPDIR come from conf/hazel.config (same <run_id>). The launcher
# is the prebuilt nextflow env (scripts/build_envs.sh --list); its bin/ goes on PATH (the bioconda wrapper needs its java) and
# Slurm exports this environment to every task job (apptainer for the images, NXF_OFFLINE: compute nodes are offline).
# The checkout is ZEAL/zealgt unless ZG_REPO names another one (e.g. the genotype session's); the log starts with that REPO
# and its full commit, and every nextflow console line carries a timestamp.
# No `set -u` here (the user's shell init trips on it).
#SBATCH --job-name=zealgt_head
#SBATCH --account=maize_cpu
#SBATCH --partition=compute_partners
#SBATCH --qos=short
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/share/maize/frodrig4/nf_work/zealgt_head_%j.log

set -eo pipefail
RUN_ID="$1"; shift || true
[ -n "$RUN_ID" ] || { echo "usage: sbatch scripts/submit_head_job.sbatch <run_id> <nextflow run args>" >&2; exit 2; }
case "$RUN_ID" in *[!A-Za-z0-9_.-]*) echo "run_id '$RUN_ID': letters, digits, _ . - only" >&2; exit 2 ;; esac

REPO="${ZG_REPO:-/rsstu/users/r/rrellan/BZea/ZEAL/zealgt}"
echo "$(date '+%F %T') zealgt_head repo=$REPO"
echo "$(date '+%F %T') zealgt_head commit=$(git -C "$REPO" rev-parse HEAD)"
# Every image the modules name in the Apptainer cache, and the launcher, before nextflow starts: /share deletes files not
# read for 30 days, and a missing image would otherwise fail only the first task that needs it. Stat only (no file read, so
# the check never resets the access clock); on a miss it prints the restore command and the head job stops.
ZG_REPO="$REPO" bash "$REPO/scripts/restore_images.sbatch" --check || exit 1
NXF_PREFIX="$(bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' '$1 == "nextflow" { print $5 }')"

export NXF_OFFLINE=true NXF_ANSI_LOG=false
export NXF_PLUGINS_DIR="$NXF_PREFIX/share/nextflow/plugins"
# apptainer for the task images (the binary itself: the site module fails when TMPDIR is unset). hazel's miniconda is no
# longer added (the tasks run in containers; the launcher's own bin/ is enough for nextflow + java).
export PATH="$NXF_PREFIX/bin:/usr/local/apps/apptainer/1.4.2-1/bin:$PATH"

LAUNCH=/share/maize/frodrig4/nf_work/$RUN_ID/launch
mkdir -p "$LAUNCH"
cd "$LAUNCH"
echo "zealgt_head job=$SLURM_JOB_ID run_id=$RUN_ID repo=$REPO commit=$(git -C "$REPO" rev-parse --short HEAD) nextflow=$NXF_PREFIX launch=$LAUNCH"
echo "args: $*"
# Every console line of nextflow gets a timestamp (gawk strftime; hazel's awk is GNU Awk 5.1); the job exits with nextflow's
# status, not awk's (set +e, so a failing pipeline does not end the script before PIPESTATUS is read).
set +e
nextflow run "$REPO" --run_id "$RUN_ID" "$@" 2>&1 | awk '{ print strftime("%F %T"), $0; fflush() }'
rc=${PIPESTATUS[0]}
set -e
echo "$(date '+%F %T') zealgt_head nextflow exit=$rc"
exit "$rc"
