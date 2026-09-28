#!/usr/bin/env bash
# Parse the config under each zealgt profile combination with the local Nextflow 26.04.6 (no run; `nextflow config`).
export NXF_VER=26.04.6 NXF_HOME=/private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/nxfhome
NF=/Users/fvrodriguez/repos/zealgt/agent/bin/nextflow
cd /Users/fvrodriguez/repos/zealgt
for prof in hazel hazel,stub hazel,short hazel,normal hazel,local stub local; do
  echo "=== -profile $prof"
  "$NF" config -profile "$prof" . > /private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/cfg_${prof//,/_}.txt 2>&1
  rc=$?
  echo "rc=$rc"
  grep -E "^workDir|executor = |queue = |clusterOptions|resourceLimits|queueSize|TMPDIR|ZG_|conda \{|enabled = |maxRetries|withName:(FASTQC|DEMUX)" -A0 /private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/cfg_${prof//,/_}.txt | head -30
  [ $rc -ne 0 ] && tail -20 /private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/cfg_${prof//,/_}.txt
done
