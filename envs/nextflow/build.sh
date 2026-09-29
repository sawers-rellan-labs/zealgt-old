#!/usr/bin/env bash
# Runs inside the new nextflow env (scripts/build_envs.sh, xfer node with internet). Fetches the plugins the pipeline declares
# in nextflow.config (`plugins { id 'nf-schema@2.5.1' }`) into the prefix, so the head job runs with NXF_OFFLINE=true and
#   NXF_PLUGINS_DIR=$CONDA_PREFIX/share/nextflow/plugins
# Keep the version here equal to nextflow.config; changing it changes this file and so the env's sha (a new prefix).
# zg-source: nextflow-plugin nf-schema@2.5.1
set -eo pipefail
: "${CONDA_PREFIX:?build.sh must run inside the env}"
# The user's login env exports NXF_OFFLINE=true (Slurm propagates it into the xfer job), which makes
# `plugin install` fail with "Plugin with id nf-schema not found in any repository". This step needs the network.
export NXF_OFFLINE=false
export NXF_HOME="$CONDA_PREFIX/share/nextflow/home"
export NXF_PLUGINS_DIR="$CONDA_PREFIX/share/nextflow/plugins"
mkdir -p "$NXF_HOME" "$NXF_PLUGINS_DIR"
nextflow -version
nextflow plugin install nf-schema@2.5.1
test -d "$NXF_PLUGINS_DIR/nf-schema-2.5.1"
echo "nf-schema@2.5.1 installed in $NXF_PLUGINS_DIR"
