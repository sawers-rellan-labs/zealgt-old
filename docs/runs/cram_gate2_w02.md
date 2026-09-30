# cram_gate2_w02 — CRAM Gate 2, wave 2 of 3

**Status:** approved by the user 2026-09-29; w01 + b73 submitted 2026-09-29; **w02 not submitted**: awaits the coordinator's
review of w01 (no failed task, checkpoints removable, ALIGN_MARKDUP memory peaks).

## Purpose
CRAM Gate 2 (docs/PLAN_pipeline.md §6), second wave. Holds the deepest samples of the Gate 2 set (2H 140 M pairs, 2B 131 M).
After waves 1 + 2 every Zx.0540_P3 library (2A 2B 2F BZea5 BZea6) is in the store.

## Selection
- Whole libraries, `meta/registry.csv` `donor_resolved` ∈ {Zx.0540_P3, Zx.0570_P2}. Named donors: Zx.0540_P3 26 samples
  (2B 1, BZea6 25), Zx.0570_P2 2 (2H 1, 3C 1).

| library | type | samples | lanes | raw | force_demux |
|---|---|---|---|---|---|
| 2B | BC1 | 12 | 3 | 143 GB | yes |
| 2H | BC1 | 12 | 3 | 150 GB | yes |
| 3C | BC1 | 12 | 4 | 111 GB | yes |
| BZea6 | batch-1 plate | 96 (2 checks) | 2 tar members | 64 GB | no |

## Inputs
- `docs/runs/cram_gate2_w02.csv`, `docs/runs/cram_gate2_w02.yml`.
- `--max_libraries 8` (user 2026-09-29: checkpoints kept through the genotype Gate 2, so w01's 4 dirs + 4 requested).

## Command
```
ssh hazel 'sbatch --qos=normal --partition=compute --time=3-00:00:00 --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch cram_gate2_w02 -profile hazel,normal -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/docs/runs/cram_gate2_w02.yml'
```

## Expected resources
- Wall ~4-5.5 h (ALIGN of the 140 M-pair 2H sample 3.1-3.7 h); part of the ~2,000-2,300 CPU-h Gate 2 total.
- `work/` peak ≈ 1.4 TB (largest wave), ~11 K files; checkpoint +0.39 TB (0.75 TB held after the wave).

## Outputs / done
As w01 for these 132 samples; outdir `ZEAL/results/zealgt/cram_gate2_w02`; checkpoints kept.
