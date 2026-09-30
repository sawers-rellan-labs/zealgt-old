# CLAUDE.md

## Scratch space: `agent/`

`agent/` is the scratch folder for agent work (scripts, intermediate outputs, handovers). It is gitignored.

## Shell rules

1. **No multiline commands in the terminal.** Anything longer than a single line goes into a script in `agent/`, and then that script is run. Script names start with a timestamp in the form `YYYYMMDD_HHMMSS_<short_description>.<ext>`, e.g. `agent/20260925_143000_count_snps.sh`.
2. **No recursive removals without explicit consent.** Never run `rm -r`, `rm -rf`, `find ... -delete`, `git clean -fdx`, or anything similar unless the user has explicitly approved that specific removal first.

## Hazel debug loop

Running, submitting or debugging anything on the hazel cluster follows the **`hazel-debug-loop` skill**
(`.claude/skills/hazel-debug-loop/`, adapted from zealbc1): git-only transfer, Slurm `short` QOS for all compute, the fix loop, and
killing a run safely. Invoke it when iterating on hazel. The testing ladder (gates) is in `docs/PLAN_pipeline.md` §6.
Writing, reviewing or pushing pipeline code (modules, subworkflows, configs, schemas) follows the **`nfcore-compliance` skill**
(`.claude/skills/nfcore-compliance/`): nf-core spec rules, module patching, deliberate deviations, pre-push checklist.

## Logging in task scripts

Adopted from zealbc1 (`CLAUDE.md`, "R script conventions"). Every module template logs timestamped, tagged messages to
**stderr** (so they land in the task's `.command.err`), never bare `print`/`cat`/`message`:

- **R:** the `logger` package (lab convention), sprintf-style: `log_info("[rtiger] donor %s | %d lines", donor, n)`;
  `log_info/log_warn/log_error`, no `paste`/`sprintf` inside.
- **Python:** the standard `logging` module, configured once per template:
  `logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(asctime)s %(levelname)s [%(name)s] %(message)s")`,
  logger named after the process (`log = logging.getLogger("pooled_likelihood_tiers")`).
- **Progress about once a minute** (user, 2026-09-30): any step that can run longer than a minute logs a progress line
  roughly every minute, throttled by time, not by iteration count, with a running ETA, so a slow task can be told from a
  hung one: `>>> %d/%d done | elapsed %.1f min | ETA ~%.1f min remaining` (elapsed from a start time set before the loop).
  Log less often only when logging itself becomes an I/O issue (e.g. a line per site in a loop over millions of sites).

Logs handed to the user to follow (`tail -f`) must update line by line: no block-buffering filters between a command and
its log file (`sed -l`, `stdbuf -oL`, `grep --line-buffered`, or write the file directly).
