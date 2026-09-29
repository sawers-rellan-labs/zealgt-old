#!/usr/bin/env bash
# Fix round: scripts/test_cache.sh local on the committed HEAD (b08b8d3); pigz shim that takes -p first on PATH.
cd /Users/fvrodriguez/repos/zealgt-simplify || exit 1
A=/Users/fvrodriguez/repos/zealgt/agent
export ZG_CACHETEST_PATH="/Users/fvrodriguez/repos/zealgt-simplify/agent/localbin_pigzp:$A/bin:$A/localbin:/opt/homebrew/bin"
bash scripts/test_cache.sh local
echo "test_cache exit: $?"
