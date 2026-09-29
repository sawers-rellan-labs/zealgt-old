# cram_gate2_w03 — CRAM Gate 2, wave 3 of 3

**Status:** approved by the user 2026-09-29; w01 + b73 submitted 2026-09-29; **w03 not submitted**: awaits the coordinator's
review of w01 (and then w02).

## Purpose
CRAM Gate 2 (docs/PLAN_pipeline.md §6), last wave. After it every Zx.0570_P2 library (2H 3B 3C 3D 3E BZea8 BZea9) is in the
store. First full-size run of batch-1 DEMUX on hazel (unmeasured so far): record its time.

## Selection
- Whole libraries, `meta/registry.csv` `donor_resolved` ∈ {Zx.0540_P3, Zx.0570_P2}. Named donors: Zx.0570_P2 46 samples
  (3D 1, 3E 1, BZea8 34, BZea9 10).

| library | type | samples | lanes | raw | force_demux |
|---|---|---|---|---|---|
| 3D | BC1 | 12 | 4 | 100 GB | yes |
| 3E | BC1 | 12 | 4 | 109 GB | yes |
| BZea8 | batch-1 plate | 96 (4 checks) | 2 tar members | 91 GB | no |
| BZea9 | batch-1 plate | 96 (2 checks) | 2 tar members | 68 GB | no |

## Inputs
- `docs/runs/cram_gate2_w03.csv`, `docs/runs/cram_gate2_w03.yml`.
- `--max_libraries 12` (user 2026-09-29: 8 kept checkpoint dirs from w01-w02 + 4 requested).

## Command
```
ssh hazel 'sbatch --qos=normal --partition=compute --time=3-00:00:00 --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch cram_gate2_w03 -profile hazel,normal -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/docs/runs/cram_gate2_w03.yml'
```

## Expected resources
- Wall ~2.5-3 h (throughput-bound; batch-1 DEMUX ~1 h per lane, estimated); part of the ~2,000-2,300 CPU-h Gate 2 total.
- `work/` peak ≈ 1.1 TB, ~17 K files; checkpoint +0.30 TB (1.05 TB held after the wave).

## Outputs / done
As w01 for these 216 samples; outdir `ZEAL/results/zealgt/cram_gate2_w03`; checkpoints kept until the genotype Gate 2 passes.
