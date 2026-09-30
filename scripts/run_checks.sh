#!/usr/bin/env bash
# scripts/run_checks.sh — the local replacement for nf-core's GitHub Actions CI (no GitHub CI for zealgt: .nf-core.yml,
# docs/CONTRIBUTING.md). Run it on the laptop before every push; it stops at the first failing check.
#
#   bash scripts/run_checks.sh            registry rebuild check, env prefix config check, nf-core lint, schema lint, nextflow
#                                         lint, no task.* in ext.args closures, nf-test (all local tests, stub), resolved hazel
#                                         resources (scripts/check_resources.sh)
#   bash scripts/run_checks.sh --quick    registry rebuild check, env prefix config check, the three lints and the ext.args
#                                         check only
#
# Needs on PATH: nextflow (>= 25.10.4; NXF_VER pins it), nf-core (tools 4.1), nf-test (0.9.x). ZG_CHECK_PATH is prepended to
# PATH when set, e.g. the laptop's local tool dirs. The nf-test stub runs still evaluate the tool versions of the modules
# (`eval` outputs), so on a machine without the tools ZG_CHECK_PATH must also hold version shims (fastqc, multiqc,
# picard, samtools, cutadapt, pigz) that print the pinned versions; the snapshots were recorded with those
# (docs/CONTRIBUTING.md). Laptop example:
#   ZG_CHECK_PATH=$PWD/agent/bin:$PWD/agent/.venv_nfcore/bin:$PWD/agent/stubbin NXF_VER=26.04.6 bash scripts/run_checks.sh
#
# Log: every line of the run, with a [HH:MM:SS] stamp, goes to the terminal and, line by line, to
# agent/run_checks_<YYYYMMDD_HHMMSS>.log; agent/run_checks_latest.log links to the newest (follow it with `tail -F`).
# ZG_CHECK_LOG=<file> writes there instead.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
[ -z "${ZG_CHECK_PATH:-}" ] || export PATH="$ZG_CHECK_PATH:$PATH"
export NXF_ANSI_LOG=false

if [ -z "${ZG_CHECK_LOG:-}" ]; then
    mkdir -p "$REPO/agent"
    ZG_CHECK_LOG="$REPO/agent/run_checks_$(date +%Y%m%d_%H%M%S).log"
    ln -sfn "$(basename "$ZG_CHECK_LOG")" "$REPO/agent/run_checks_latest.log"
fi
# stamp every line (perl: line-buffered, unlike sed/awk writing to a file) and tee it to the log
# (colour codes stripped); the EXIT trap closes the pipe and gives it a moment, so the last lines reach the log
exec > >(perl -MPOSIX -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*[A-Za-z]//g; $_ = strftime("[%H:%M:%S] ", localtime) . $_' | tee -a "$ZG_CHECK_LOG") 2>&1
trap 'rc=$?; exec >&- 2>&-; sleep 1; exit $rc' EXIT
T_START=$(date +%s)
echo "run_checks: log $ZG_CHECK_LOG (commit $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet || echo ', uncommitted changes'))"

step() { printf '\n##### %s (%d s elapsed)\n' "$*" "$(( $(date +%s) - T_START ))"; }

step "sample registry: rebuild meta/{registry,samples,accessions}.csv from meta/sources/ (sha256-pinned) and diff"
python3 meta/build_samples.py --check

step "conf/env_prefixes.config matches the environment.yml / build.sh contents (scripts/build_envs.sh --check-config)"
bash scripts/build_envs.sh --check-config

step "nf-core pipelines lint (must report 0 failed)"
nf-core pipelines lint --dir . 2>&1 | tee /dev/stderr | grep -qE '\[✗\] +0 Tests Failed' || { echo "nf-core lint: failures" >&2; exit 1; }

step "nf-core pipelines schema lint"
nf-core pipelines schema lint nextflow_schema.json

step "nextflow lint (errors fail, warnings are reported)"
nextflow lint main.nf workflows subworkflows/local modules/local nextflow.config conf

step "no task.* inside an ext.args closure in conf/*.config (it enters the task hash; nextflow-cache skill)"
python3 scripts/check_ext_args.py

if [ "${1:-}" = "--quick" ]; then
    echo "quick checks passed ($(( $(date +%s) - T_START )) s)"
    exit 0
fi

step "nf-test (local modules, local subworkflows, pipeline; stub)"
nf-test test --tag stub

step "resolved hazel resources per process (hazel,normal and hazel,short stub runs vs tests/expected_resources.tsv)"
bash scripts/check_resources.sh

echo "all checks passed ($(( $(date +%s) - T_START )) s)"
