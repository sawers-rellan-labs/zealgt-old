#!/bin/bash
#SBATCH --job-name=zealgt_build_envs
#SBATCH --account=maize_cpu
#SBATCH --partition=xfer
#SBATCH --mem=8G
#SBATCH --cpus-per-task=2
#SBATCH --time=08:00:00
#SBATCH --output=/share/maize/frodrig4/nf_work/build_envs_%j.log
#
# Builds every zealgt environment (bin/build_envs.sh) on the xfer partition — the only nodes with internet; compute nodes
# are offline, so no env is ever built at task time. Envs go to /share/maize/frodrig4/conda/zealgt/<id>-<sha8>, never /rsstu.
#
# Submit from the zealgt checkout on hazel (after `git pull`), one plain command:
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && sbatch bin/build_envs.sbatch            # all envs, launcher first
#   cd /rsstu/users/r/rrellan/BZea/ZEAL/zealgt && sbatch bin/build_envs.sbatch nextflow   # only the listed env ids
# Log: /share/maize/frodrig4/nf_work/build_envs_<jobid>.log; manifest: /share/maize/frodrig4/conda/zealgt/manifest.tsv
# (no `set -u`: see the hazel-debug-loop skill)
set -eo pipefail

REPO="${SLURM_SUBMIT_DIR:?submit with sbatch from the zealgt checkout}"
[ -f "$REPO/bin/build_envs.sh" ] || { echo "not a zealgt checkout: $REPO (cd into ZEAL/zealgt before sbatch)" >&2; exit 1; }

echo "zealgt build_envs: job ${SLURM_JOB_ID} on $(hostname), repo $REPO at $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ $# -gt 0 ]; then
    bash "$REPO/bin/build_envs.sh" --only "$@"
else
    bash "$REPO/bin/build_envs.sh"
fi
