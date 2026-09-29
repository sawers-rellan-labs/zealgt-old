#!/bin/bash
#SBATCH --job-name=zealgt_build_envs
#SBATCH --account=maize_cpu
#SBATCH --partition=xfer
#SBATCH --mem=8G
#SBATCH --cpus-per-task=2
#SBATCH --time=08:00:00
#SBATCH --output=/share/maize/frodrig4/nf_work/build_envs_%j.log
#
# Builds every zealgt environment (scripts/build_envs.sh) on the xfer partition — the only nodes with internet; compute nodes
# are offline, so no env is ever built at task time. Envs go to /share/maize/frodrig4/conda/zealgt/<first dependency>-<sha8>
# (keyed on content: identical envs share one prefix; scripts/build_envs.sh --prefixes), never /rsstu. Nothing is deleted.
#
# Submit on hazel (after `git pull` in the checkout); the checkout is ZG_REPO if set, else the directory sbatch ran in:
#   ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt sbatch --export=ALL /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/build_envs.sbatch
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && sbatch scripts/build_envs.sbatch            # all envs, launcher first
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && sbatch scripts/build_envs.sbatch nextflow   # only the prefixes of these env ids
# Log: /share/maize/frodrig4/nf_work/build_envs_<jobid>.log; manifest: /share/maize/frodrig4/conda/zealgt/manifest.tsv
# (no `set -u`: see the hazel-debug-loop skill)
set -eo pipefail

REPO="${ZG_REPO:-${SLURM_SUBMIT_DIR:?submit with sbatch from the zealgt checkout or set ZG_REPO}}"
[ -f "$REPO/scripts/build_envs.sh" ] || { echo "not a zealgt checkout: $REPO (cd into ZEAL/zealgt before sbatch)" >&2; exit 1; }

echo "zealgt build_envs: job ${SLURM_JOB_ID} on $(hostname), repo $REPO at $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ $# -gt 0 ]; then
    bash "$REPO/scripts/build_envs.sh" --only "$@"
else
    bash "$REPO/scripts/build_envs.sh"
fi
