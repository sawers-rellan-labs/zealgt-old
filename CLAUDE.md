# CLAUDE.md

## Scratch space: `agent/`

`agent/` is the scratch folder for agent work (scripts, intermediate outputs, handovers). It is gitignored.

## Shell rules

1. **No multiline commands in the terminal.** Anything longer than a single line goes into a script in `agent/`, and then that script is run. Script names start with a timestamp in the form `YYYYMMDD_HHMMSS_<short_description>.<ext>`, e.g. `agent/20260925_143000_count_snps.sh`.
2. **No recursive removals without explicit consent.** Never run `rm -r`, `rm -rf`, `find ... -delete`, `git clean -fdx`, or anything similar unless the user has explicitly approved that specific removal first.
