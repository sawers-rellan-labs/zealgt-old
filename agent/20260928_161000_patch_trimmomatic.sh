#!/usr/bin/env bash
# Fix round G1: regenerate the TRIMMOMATIC patch (adds ext.args3 before the inputs, for -phred33). The tool refuses to
# overwrite an existing .diff non-interactively, so the old one is moved aside to agent/ first (no rm).
set -uo pipefail
R=/Users/fvrodriguez/repos/zealgt-simplify
A=$R/agent
NFC=/Users/fvrodriguez/repos/zealgt/agent/.venv_nfcore/bin/nf-core
cd "$R" || exit 1
export PATH=/Users/fvrodriguez/repos/zealgt/agent/bin:$PATH NXF_VER=26.04.6
[ -e modules/nf-core/trimmomatic/trimmomatic.diff ] && mv modules/nf-core/trimmomatic/trimmomatic.diff "$A/20260928_161000_trimmomatic.diff.prev"
yes | "$NFC" modules patch trimmomatic 2>&1 | tail -20
echo "== diff vs previous patch"
diff "$A/20260928_161000_trimmomatic.diff.prev" modules/nf-core/trimmomatic/trimmomatic.diff
echo "== modules.json trimmomatic"
grep -n -A5 '"trimmomatic"' modules.json
