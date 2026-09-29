# cram_gate2_w01 — CRAM Gate 2, wave 1 of 3 (and the ALIGN_MARKDUP memory test)

**Status:** approved by the user 2026-09-29; w01 + b73 submitted 2026-09-29 (head 992883). **Gate 2 paused by the user
2026-09-29 ~19:45** for containerization (PLAN §6 status + TODO). The BC1 part (2A, 2F, 3B) is running into `ZEAL/store` (at 19:40:
22 of 36 ALIGN_MARKDUP done at attempt 1, peaks 32.4–36.2 of 48 GB; checkpoint 0.80–0.81 × raw); **BZea5 not done** — batch-1
DEMUX OOM-killed at 2 and 4 GB, then hung to the time limit (fix in progress, `conf/hazel.config` DEMUX TODO). Measurements:
docs/REQUIREMENTS.md §4 "CRAM Gate 2 wave 1".

## Purpose
CRAM Gate 2 (docs/PLAN_pipeline.md §6): the libraries holding the two genotype development donors, at full depth, into the
production store, with the per-module benchmark into docs/REQUIREMENTS.md. Wave 1 holds every raw layout (3-lane BC1, 4-lane
BC1, batch-1 tar members), so a layout failure shows in the first wave. It is also the **full-depth ALIGN_MARKDUP memory test**
(PLAN §6 "Memory test", user 2026-09-29): the coordinator reviews its first-attempt peak RSS against 0.95 × the request before
wave 2 (whose 2B / 2H carry the deepest samples, 131-140 M pairs).

## Selection
- Whole libraries (a library is demultiplexed once, all its samples; no sub-plate input). Criterion: `meta/registry.csv`
  `donor_resolved` ∈ {Zx.0540_P3, Zx.0570_P2} (taxon Zx); no coverage (λ) or NIL filter applies at the CRAM stage.
- Named donors in this wave: Zx.0540_P3 19 samples (2A 2, 2F 2, BZea5 15), Zx.0570_P2 1 (3B).

| library | type | samples | lanes | raw | force_demux |
|---|---|---|---|---|---|
| 2A | BC1 | 12 | 3 (L5-L7) | 133 GB | yes (registry seed) |
| 2F | BC1 | 12 | 3 (L5-L7) | 122 GB | yes |
| 3B | BC1 | 12 | 4 (L1-L4) | 107 GB | yes |
| BZea5 | batch-1 plate | 96 (5 checks) | 2 tar members | 74 GB | no (not registered) |

- Exclusions: BZeaRP1 (brbseq, not a CRAM-workflow source); all other libraries. None of these 132 samples is in the store.

## Inputs
- `docs/runs/cram_gate2_w01.csv` (rows of meta/samples.csv, verbatim) and `docs/runs/cram_gate2_w01.yml` (params).
- Code: main at the commit that added this card (pipeline tree = simplify 63b48bf; CodeRabbit 0 findings on 258f4a3).
- `--max_libraries 4`: the checkpoint root holds no library yet.

## Command
```
ssh hazel 'sbatch --qos=normal --partition=compute --time=3-00:00:00 --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch cram_gate2_w01 -profile hazel,normal -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/docs/runs/cram_gate2_w01.yml'
```
workDir `/share/maize/frodrig4/nf_work/cram_gate2_w01/work`.

## Expected resources
- Wall ~5-5.5 h (queue waits excluded); CPU-h ~one third of the Gate 2 total (~2,000-2,300 CPU-h allocated for all waves + b73).
- `work/` peak ~3 × raw ≈ 1.3 TB, ~11 K files; checkpoint kept ≈ 0.83 × raw ≈ 0.36 TB; store +~125 GB CRAMs, 1,056 files.

## Outputs / done
- Store `ZEAL/store/{cram,demux_qc,registry,provenance}` for the 132 samples; results `ZEAL/results/zealgt/cram_gate2_w01`;
  checkpoint `/share/maize/frodrig4/fastq_checkpoint/{2A,2F,3B,BZea5}` **kept** until the genotype Gate 2 passes.
- Done: head job ended with no failed task, every CRAM stored and verified, every `zealgt: checkpoint <dir>: removable` line,
  ALIGN_MARKDUP first-attempt peaks recorded (memory test), measured resources into docs/REQUIREMENTS.md.
