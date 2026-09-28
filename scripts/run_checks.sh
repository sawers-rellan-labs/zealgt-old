#!/usr/bin/env bash
# scripts/run_checks.sh — the local replacement for nf-core's GitHub Actions CI (no GitHub CI for zealgt: .nf-core.yml,
# docs/CONTRIBUTING.md). Run it on the laptop before every push; it stops at the first failing check.
#
#   bash scripts/run_checks.sh            registry rebuild check, nf-core lint, schema lint, nextflow lint, nf-test (stub)
#   bash scripts/run_checks.sh --quick    registry rebuild check and the three lints only
#
# Needs on PATH: nextflow (>= 25.10.4; NXF_VER pins it), nf-core (tools 4.1), nf-test (0.9.x). ZG_CHECK_PATH is prepended to
# PATH when set, e.g. the laptop's local tool dirs. The nf-test stub runs still evaluate the tool versions of the nf-core
# modules (`eval` outputs), so on a machine without the tools ZG_CHECK_PATH must also hold version shims (fastqc, multiqc,
# picard, samtools, trimmomatic, cutadapt, pigz) that print the pinned versions; the snapshots were recorded with those
# (docs/CONTRIBUTING.md). Laptop example:
#   ZG_CHECK_PATH=$PWD/agent/bin:$PWD/agent/.venv_nfcore/bin:$PWD/agent/stubbin NXF_VER=26.04.6 bash scripts/run_checks.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
[ -z "${ZG_CHECK_PATH:-}" ] || export PATH="$ZG_CHECK_PATH:$PATH"
export NXF_ANSI_LOG=false

step() { printf '\n##### %s\n' "$*"; }

step "sample registry: rebuild meta/{registry,samples,accessions}.csv from meta/sources/ (sha256-pinned) and diff"
python3 meta/build_samples.py --check

step "nf-core pipelines lint (must report 0 failed)"
nf-core pipelines lint --dir . 2>&1 | tee /dev/stderr | grep -qE '\[✗\] +0 Tests Failed' || { echo "nf-core lint: failures" >&2; exit 1; }

step "nf-core pipelines schema lint"
nf-core pipelines schema lint nextflow_schema.json

step "nextflow lint (errors fail, warnings are reported)"
nextflow lint main.nf workflows subworkflows/local modules/local nextflow.config conf

if [ "${1:-}" = "--quick" ]; then
    echo "quick checks passed"
    exit 0
fi

step "nf-test (local modules, local subworkflows, pipeline; stub)"
nf-test test --tag stub

echo "all checks passed"
