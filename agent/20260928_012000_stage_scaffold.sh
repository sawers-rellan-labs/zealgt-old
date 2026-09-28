#!/usr/bin/env bash
# Stage exactly the scaffold files copied into the repo (explicit paths, no -A), plus the template YAML.
set -eo pipefail
SRC=/Users/fvrodriguez/repos/zealgt/agent/20260928_011000_scaffold/zealgt
DST=/Users/fvrodriguez/repos/zealgt
cd "$SRC"
files=()
while read -r f; do
  case "$f" in .gitignore|README.md) continue;; esac
  files+=("$f")
done < <(find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | sort)
git -C "$DST" add -- "${files[@]}"
git -C "$DST" add -f agent/20260928_011000_nfcore_template.yml agent/20260928_010500_phaseA_local_tooling.sh agent/20260928_011500_copy_scaffold.sh agent/20260928_012000_stage_scaffold.sh
git -C "$DST" status --short | grep -v '^??' | wc -l
