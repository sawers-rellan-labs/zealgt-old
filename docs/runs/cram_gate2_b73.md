# cram_gate2_b73 — CRAM Gate 2, B73 controls (markdup_import)

**Status:** approved by the user 2026-09-29; w01 + b73 submitted 2026-09-29; w02/w03 await the coordinator's review of w01.

## Purpose
Put the two B73 controls of the genotype workflow into the production store (`ZEAL/store/cram_import/`) through
`--entry markdup_import` (read group from the header or the sheet, samtools markdup, no realignment → SAMTOOLS_STATS + Picard
→ PROVENANCE). Independent of the demux waves: adds no library, so neither the registry guard nor `--max_libraries` applies.

## Selection
The two `import_set b73_control` rows of meta/dev_import.csv; not in meta/registry.csv (documented exception: `row` null + note).

| sample | source file | size |
|---|---|---|
| B73_ERR3288215 | `ZEAL/results/b73_control/ERR3288215/B73_ERR3288215.cram` (+ .crai), SRA ERR3288215, 15.5x | 8.9 GB |
| B73_skim10 | `ZEAL/results/b73_control/skim10/B73_skim10.bam` (+ .bai), merge of 10 batch-1 B73 checks, 5.7x | 7.3 GB |

## Inputs
`docs/runs/cram_gate2_b73_import.csv` (verbatim rows), `docs/runs/cram_gate2_b73.yml` (`workflow cram`, `entry markdup_import`,
`import_sets b73_control`).

## Command
```
ssh hazel 'sbatch --qos=normal --partition=compute --time=3-00:00:00 --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch cram_gate2_b73 -profile hazel,normal -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/docs/runs/cram_gate2_b73.yml'
```
`-profile hazel,normal` because ERR3288215's CollectWgsMetrics (~2.5 h) does not fit the short QOS.

## Expected resources
~2 MARKDUP_IMPORT tasks (≤ 16 min each) + stats/Picard, a few CPU-h; wall ~3 h (Picard on ERR3288215); small `work/`.

## Outputs / done
`ZEAL/store/cram_import/` holds both CRAMs (+ crai, stats, provenance); results `ZEAL/results/zealgt/cram_gate2_b73`. Done:
head job ended with no failed task and both samples stored and verified. The genotype branch reads them as role `b73_control`,
`store_dir cram_import`.
