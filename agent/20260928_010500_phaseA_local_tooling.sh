#!/usr/bin/env bash
# Phase A: local tooling (nf-core tools venv, Nextflow launcher, nf-test) under agent/
set -eo pipefail
A=/Users/fvrodriguez/repos/zealgt/agent
[ -d "$A/.venv_nfcore" ] || python3 -m venv "$A/.venv_nfcore"
"$A/.venv_nfcore/bin/pip" install --upgrade pip
"$A/.venv_nfcore/bin/pip" install nf-core
"$A/.venv_nfcore/bin/nf-core" --version
# Nextflow launcher pinned to 26.04.6 (hazel's version)
if [ ! -x "$A/bin/nextflow" ]; then
  curl -fsSL -o "$A/bin/nextflow" https://github.com/nextflow-io/nextflow/releases/download/v26.04.6/nextflow
  chmod +x "$A/bin/nextflow"
fi
NXF_VER=26.04.6 "$A/bin/nextflow" -version
# nf-test
if [ ! -x "$A/bin/nf-test" ]; then
  (cd "$A/bin" && curl -fsSL https://get.nf-test.com | bash)
fi
"$A/bin/nf-test" version
