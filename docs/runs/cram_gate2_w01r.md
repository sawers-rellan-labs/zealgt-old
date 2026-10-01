# cram_gate2_w01r — CRAM Gate 2, wave 1 restart: the 13 missing BC1 CRAMs from the FASTQ checkpoint

**Status:** draft 2026-10-01, awaiting the user's approval.

## Purpose
w01 (head 992883, `docs/runs/cram_gate2_w01.md`) was stopped by the user on 2026-09-29 at 19:43 for the container switch,
with 23 of the 36 BC1 CRAMs of 2A, 2F, 3B stored. This run aligns the other 13 from the kept FASTQ checkpoint
(`/share/maize/frodrig4/fastq_checkpoint/{2A,2F,3B}`, written 2026-09-29), before /share's 30-day purge may remove it
(≈ 2026-10-29; then those libraries would start again from the raw reads). It is also the first full-depth ALIGN_MARKDUP run
on containers. The batch-1 DEMUX fix (branch `demux-batch1-fix`, from `gate2-bug`) is not needed here: stage 2 runs no DEMUX.

## Selection (store and checkpoint checked 2026-10-01, stat only)
| library | checkpoint samples | stored | to align |
|---|---|---|---|
| 2A | 12 | 5 | S_2A_1, 2, 3, 4, 6, 8, 9 |
| 2F | 12 | 7 | S_2F_2, 4, 5, 6, 8 |
| 3B | 12 | 11 | S_3B_6 |

None of the 13 has a partial file in the store (the start-up guard refuses a CRAM without .crai / EOF block).

## Inputs
- `docs/runs/cram_gate2_w01r.yml` (params); the checkpoint samplesheets `<fastq_checkpoint>/<lib>/samplesheet.csv`.
- Code: main at the commit that adds this card; containers (`-profile hazel` = Apptainer, 18 images checked present by the
  head job). CodeRabbit on the executing changes since the last review (d94158f..90f025c: `scripts/restore_images.sbatch`,
  `submit_head_job.sbatch`, `test_cache.sbatch`); the alignment path is unchanged since the containers Gate 1.

## Command
```
ssh hazel 'sbatch --qos=normal --partition=compute --time=3-00:00:00 --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/scripts/submit_head_job.sbatch cram_gate2_w01r -profile hazel,normal -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt/docs/runs/cram_gate2_w01r.yml'
```
workDir `/share/maize/frodrig4/nf_work/cram_gate2_w01r/work`.

## Expected resources
- 13 ALIGN_MARKDUP tasks, 8.2–11.2 GiB of trimmed pairs each: requests 2.9–3.9 h, 8 cpu, 48 GB (w01 peaks 32.4–36.2 of
  48 GB); ≤ ~350 CPU-h requested in all, less used. All run concurrently if the queue allows: wall ~4 h + queue waits.
- Then SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS, PROVENANCE per sample; REGISTRY per library (demux_qc of the three is in
  the store).
- Store +13 CRAMs ≈ 48 GiB (46–52): CRAM = 0.384 × the trimmed input (0.366–0.417 over the 23 stored w01 BC1 CRAMs), applied
  to each missing sample's own checkpoint input (they are the larger samples: 3.1–4.3 GiB each vs a 2.4 GiB mean stored);
  ~13 × 8 files; `work/` the same CRAMs plus the
  QC files; sort temporaries in the run's TMPDIR on /share while each task runs.

## Outputs / done
- Store `ZEAL/store/{cram,provenance,registry}` for the 13 samples; results `ZEAL/results/zealgt/cram_gate2_w01r`.
- Done: head job ended with no failed task; all 36 CRAMs of 2A, 2F, 3B stored and verified; ALIGN_MARKDUP first-attempt
  peaks recorded (container memory accounting) in docs/REQUIREMENTS.md. The checkpoint stays until the genotype Gate 2
  passes (removal: the user's call, cleanup 2).
