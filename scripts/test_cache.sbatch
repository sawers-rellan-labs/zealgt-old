#!/bin/bash
# scripts/test_cache.sbatch — head job for `scripts/test_cache.sh hazel` (cache / stage-split test at Gate 1 scale: 1A,
# --subsample 1000000, -profile hazel,short; tasks are Slurm jobs, this job only drives Nextflow). Never on the login node.
#
#   sbatch scripts/test_cache.sbatch
#   ZG_REPO=<other checkout> sbatch --export=ALL,ZG_REPO scripts/test_cache.sbatch
#
# The checkout is ZEAL/zealgt unless ZG_REPO names another one; test_cache.sh clones its HEAD into the scratch dir
# (/share/maize/frodrig4/nf_work/simplify_cachetest/<time>, or $ZG_CACHETEST_ROOT/<time>). The log starts with that REPO and
# its full commit, and every line carries a timestamp. Five Nextflow runs (R1, stub preflight, R2, R3, R4): about 1 h at
# Gate 1 scale, within short's 2 h; if not, resubmit with --qos=normal --partition=compute --time=04:00:00.
# 1 cpu, 8 GB as scripts/submit_head_job.sbatch. No `set -u` (the user's shell init trips on it).
#SBATCH --job-name=zealgt_cachetest
#SBATCH --account=maize_cpu
#SBATCH --partition=compute_partners
#SBATCH --qos=short
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/share/maize/frodrig4/nf_work/zealgt_cachetest_%j.log

set -eo pipefail
REPO="${ZG_REPO:-/rsstu/users/r/rrellan/BZea/ZEAL/zealgt}"
echo "$(date '+%F %T') zealgt_cachetest repo=$REPO"
echo "$(date '+%F %T') zealgt_cachetest commit=$(git -C "$REPO" rev-parse HEAD)"
NXF_PREFIX="$(bash "$REPO/scripts/build_envs.sh" --list | awk -F'\t' '$1 == "nextflow" { print $5 }')"
[ -x "$NXF_PREFIX/bin/nextflow" ] || { echo "nextflow env not built: $NXF_PREFIX (run scripts/build_envs.sbatch nextflow)" >&2; exit 1; }

export NXF_OFFLINE=true NXF_ANSI_LOG=false
export NXF_PLUGINS_DIR="$NXF_PREFIX/share/nextflow/plugins"
export PATH="$NXF_PREFIX/bin:/usr/local/apps/conda/miniconda3/26.3.2/bin:$PATH"
echo "$(date '+%F %T') zealgt_cachetest job=$SLURM_JOB_ID nextflow=$NXF_PREFIX"

# every line gets a timestamp (gawk strftime; hazel's awk is GNU Awk 5.1); the job exits with test_cache.sh's status
set +e
bash "$REPO/scripts/test_cache.sh" hazel 2>&1 | awk '{ print strftime("%F %T"), $0; fflush() }'
rc=${PIPESTATUS[0]}
set -e
echo "$(date '+%F %T') zealgt_cachetest exit=$rc"
exit "$rc"
