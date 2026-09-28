# CodeRabbit gate, Phase B (CRAM workflow code)

Command: `coderabbit review --committed --base-commit f02853d --agent` (the Phase B code on main since the env-only commit
f02853d; `--base main` gives an empty diff when working on main itself). CodeRabbit CLI 0.7.6.

| run | HEAD reviewed | output | findings | action |
|---|---|---|---|---|
| 1 | db56f40 | agent/20260928_071000_coderabbit_run1.txt | 1 major: MARKDUP_IMPORT kept a stale single @RG header line when the sheet RG replaced it (SM mismatch) | **applied** 049442d: header @RG lines stripped whenever rg_source != header; retested locally with 0 / 1-mismatch / 2 input RGs and the header-kept path |
| 2 | 049442d | agent/20260928_072500_coderabbit_run2.txt | 1 major: stub-run store guard accepted any path containing "stub" | **applied** 9754831: store must be a directory named store_stub* outside ZEAL/store |
| 3 | 9754831 | agent/20260928_073500_coderabbit_run3.txt | 1 major: resolve symlinks before the inside-production check | **applied** e7a2d16: zgRealPath (deepest existing ancestor via toRealPath + missing tail) |
| 4 | e7a2d16 | agent/20260928_075000_coderabbit_run4.txt | none: rate limit ("3 included reviews", wait 46 min) | retried after the wait, see below |

| 5 | db3a9c5 (base 5be18a4) | agent/20260928_160000_coderabbit_run5.txt | none: rate limit (wait 12 min) | retried |
| 5b | 30390e8 (base 5be18a4, whole Phase B incl. env commit) | agent/20260928_161500_coderabbit_run5b.txt | **0 findings** | gate passed |

Rejected findings: none.
