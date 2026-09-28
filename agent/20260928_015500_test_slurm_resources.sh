#!/usr/bin/env bash
# Exercise bin/slurm_resources.sh in the scenarios it must handle (sourced under bash -euo pipefail, like a Nextflow task).
H=/Users/fvrodriguez/repos/zealgt/bin/slurm_resources.sh
T=/private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/zgtmp
run() { local name="$1"; shift; echo "== $name"; env -i PATH="$PATH" HOME="$HOME" "$@" bash -euo pipefail -c "source $H; echo \"after: cpus=\$ZG_CPUS mem=\$ZG_MEM_MB java=\${ZG_JAVA_MEM_MB:-unset}\"" ; echo "rc=$?"; }
run "slurm per node"        SLURM_JOB_ID=1 SLURM_CPUS_PER_TASK=8 SLURM_MEM_PER_NODE=24576 TMPDIR=$T/a
run "slurm per cpu"         SLURM_JOB_ID=2 SLURM_CPUS_PER_TASK=4 SLURM_MEM_PER_CPU=3072
run "slurm small mem"       SLURM_JOB_ID=3 SLURM_CPUS_PER_TASK=1 SLURM_MEM_PER_NODE=2048
run "slurm no cpus"         SLURM_JOB_ID=4 SLURM_MEM_PER_NODE=2048
run "slurm bad mem"         SLURM_JOB_ID=5 SLURM_CPUS_PER_TASK=2 SLURM_MEM_PER_NODE=8G
run "leaked ZG under slurm" SLURM_JOB_ID=6 SLURM_CPUS_PER_TASK=2 SLURM_MEM_PER_NODE=8192 ZG_CPUS=64 ZG_MEM_MB=999999
run "local override"        ZG_RESOURCES_OVERRIDE=local ZG_CPUS=2 ZG_MEM_MB=6144
run "local override bad"    ZG_RESOURCES_OVERRIDE=local ZG_CPUS=0 ZG_MEM_MB=6144
run "nothing"
run "ZG without override"   ZG_CPUS=2 ZG_MEM_MB=6144
echo "== executed directly"; env -i PATH="$PATH" SLURM_JOB_ID=7 SLURM_CPUS_PER_TASK=2 SLURM_MEM_PER_NODE=4096 bash $H; echo "rc=$?"
