#!/usr/bin/env bash
# Trimming round: scripts/run_checks.sh with the laptop check PATH (tools from the main checkout's agent/, read-only use).
# Usage: bash agent/20260929_171000_run_checks.sh [--quick] <log tag>
cd /Users/fvrodriguez/repos/zealgt-simplify || exit 1
A=/Users/fvrodriguez/repos/zealgt/agent
MODE="${1:-}"
TAG="${2:-run}"
LOG=agent/20260929_171000_run_checks_${TAG}.txt
if [ "$MODE" = "--quick" ]; then
    ZG_CHECK_PATH=$A/bin:$A/.venv_nfcore/bin:/Users/fvrodriguez/repos/zealgt-simplify/agent/stubbin NXF_VER=26.04.6 bash scripts/run_checks.sh --quick > "$LOG" 2>&1
else
    ZG_CHECK_PATH=$A/bin:$A/.venv_nfcore/bin:/Users/fvrodriguez/repos/zealgt-simplify/agent/stubbin NXF_VER=26.04.6 bash scripts/run_checks.sh > "$LOG" 2>&1
fi
echo "run_checks exit $?"
grep -E "^#####|passed|failed|Failed|ERROR|error:|Tests Failed|Executed|problems|\[✗\]|warn" "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | tail -60
