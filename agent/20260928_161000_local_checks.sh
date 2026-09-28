#!/usr/bin/env bash
# Phase B finish: all local checks in sequence (lint, schema lint, nf-test stub, stub runs of every entry).
A=/Users/fvrodriguez/repos/zealgt/agent
export PATH="$A/bin:$A/.venv_nfcore/bin:$PATH" NXF_VER=26.04.6
echo "##### lint"; bash $A/20260928_013500_nfcore_lint.sh 2>&1 | grep -E "passed|failed|warned|Tests Failed|report" 
echo "##### schema lint"; (cd /Users/fvrodriguez/repos/zealgt && nf-core pipelines schema lint nextflow_schema.json 2>&1 | tail -5)
echo "##### nf-test"; bash $A/20260928_063500_nftest_stub.sh 2>&1 | tail -8
echo "##### stub demux"; bash $A/20260928_161000_local_stub_demux.sh 2>&1 | grep -E "ERROR|Succeeded|Failed|SUCCESS|error" | head
echo "##### stub entries"; bash $A/20260928_161000_local_stub_entries.sh
