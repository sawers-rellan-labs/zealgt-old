#!/usr/bin/env bash
# Copy the nf-core scaffold into the repo root, only files that do not exist yet; list conflicts.
set -eo pipefail
SRC=/Users/fvrodriguez/repos/zealgt/agent/20260928_011000_scaffold/zealgt
DST=/Users/fvrodriguez/repos/zealgt
cd "$SRC"
find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | sort | while read -r f; do
  if [ -e "$DST/$f" ]; then
    echo "CONFLICT (kept ours): $f"
  else
    mkdir -p "$DST/$(dirname "$f")"
    cp -p "$f" "$DST/$f"
    echo "copied: $f"
  fi
done
