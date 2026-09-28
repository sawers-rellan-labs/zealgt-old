#!/bin/bash
# scripts/submit_head_job.sbatch — the Nextflow head job of a zealgt run on hazel (never the login node; hazel-debug-loop skill).
#
#   sbatch scripts/submit_head_job.sbatch <run_id> <nextflow run args ...>
#   e.g. sbatch scripts/submit_head_job.sbatch gate0_demux -profile hazel,stub -stub --entry read_demultiplexing --libraries 1A \
#            --force_demux 1A --outdir /rsstu/users/r/rrellan/BZea/ZEAL/results/zealgt/gate0_demux
#   Longer runs (Gate 2): sbatch --qos=normal --partition=compute --time=24:00:00 scripts/submit_head_job.sbatch <run_id> ...
#
# 1 cpu, 8 GB (zealbc1 heads peaked at 3.8 of 4 GB), short QOS, 2 h. Launch directory (.nextflow/, .nextflow.log, history)
# = /share/maize/frodrig4/nf_work/<run_id>/launch; workDir and TMPDIR come from conf/hazel.config (same <run_id>). The launcher
# is the prebuilt nextflow env (scripts/build_envs.sh --list); its bin/ goes on PATH (the bioconda wrapper needs its java) and
# Slurm exports this environment to every task job (conda for the prefixes, NXF_OFFLINE: compute nodes are offline).
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

REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt
NXF_PREFIX="$(bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' '$1 == "nextflow" { print $5 }')"
[ -x "$NXF_PREFIX/bin/nextflow" ] || { echo "nextflow env not built: $NXF_PREFIX (run scripts/build_envs.sbatch nextflow)" >&2; exit 1; }

export NXF_OFFLINE=true NXF_ANSI_LOG=false
export NXF_PLUGINS_DIR="$NXF_PREFIX/share/nextflow/plugins"
export PATH="$NXF_PREFIX/bin:/usr/local/apps/conda/miniconda3/26.3.2/bin:$PATH"

LAUNCH=/share/maize/frodrig4/nf_work/$RUN_ID/launch
mkdir -p "$LAUNCH"
cd "$LAUNCH"
echo "zealgt_head job=$SLURM_JOB_ID run_id=$RUN_ID repo=$REPO commit=$(git -C "$REPO" rev-parse --short HEAD) nextflow=$NXF_PREFIX launch=$LAUNCH"
echo "args: $*"
nextflow run "$REPO" --run_id "$RUN_ID" "$@"
