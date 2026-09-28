#!/usr/bin/env bash
# Run nf-core pipelines lint on the repo root with the local tooling (agent/.venv_nfcore, agent/bin/nextflow 26.04.6).
A=/Users/fvrodriguez/repos/zealgt/agent
export PATH="$A/bin:$A/.venv_nfcore/bin:$PATH" NXF_VER=26.04.6
cd /Users/fvrodriguez/repos/zealgt
out="$A/$(date +%Y%m%d_%H%M%S)_lint"
nf-core pipelines lint --dir . --markdown "$out.md" --json "$out.json" "$@" 2>&1 | tail -80
echo "report: $out.md"
