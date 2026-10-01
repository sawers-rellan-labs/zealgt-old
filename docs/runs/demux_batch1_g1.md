# demux_batch1_g1 — batch-1 DEMUX fix: Gate 1 (BZea5, small) + full-lane memory probe

**Status:** approved by the user 2026-10-01 ("probe plus small Gate 1"; "go"). **Done 2026-10-01: both passed.**
Gate 1 head 1018793 COMPLETED (57 min 37; DEMUX 0.36 / 0.70 GB of 3 GB, attempt 1; one SAMTOOLS_STATS OOM → 2 GB). Probe job
1018848 (first attempt 1018809 failed in 1 s on two probe-script bugs: an unbound raw-data path and a `du` before `demux/` existed):
exit 0 in 53 min 35, 224 M pairs, anon 529 → 533 MB flat, 192 outputs. CPU split (job 1020547, cancelled once settled): cutadapt
workers ≈ 80 %, compression ≈ 15 %, decompression ≈ 4 %. Details: docs/REQUIREMENTS.md §4. Probe dirs removed with consent after
their records were copied to the laptop (`agent/archive/demux_probe_L001_{r2,cpu}/`).

## Purpose
CRAM Gate 2 w01 (2026-09-29): batch-1 DEMUX (BZea5, 96 barcodes, 192 outputs) was OOM-killed at 2 GB and at 4 GB, memory
growing for ~4 min of cutadapt (~15–20 M pairs of a lane), and each time the task then hung to its time limit
(docs/REQUIREMENTS.md §4, docs/PLAN_pipeline.md §6). Fix on branch `demux-batch1-fix` (from `gate2-bug`, d875d65): cutadapt
writes plain FASTQ into one FIFO per output, each compressed by `pigz -1 -p 1`; cutadapt in its own process group; the EXIT
trap stops the group and the compressors on any exit path; batch-1 DEMUX 3 GB × attempt. Laptop / Docker: run_checks all
passed (71 stub tests, resources), real DEMUX nf-tests 4/4 in the production image, failure paths end in 1–2 s
(agent/20261001_225500_test_demux_failure_paths.sh), CodeRabbit 0 findings (base cb3e72d).
This card tests it on hazel in two steps, bugs first, then the memory question at full size:
1. **Gate 1** `demux_batch1_g1`: the pipeline path, small (a Gate 1 at 1 M pairs per lane cannot show growth that appeared
   after ~15 M pairs, lesson of w01).
2. **Probe** (`scripts/probe_demux_memory.sbatch`): one DEMUX task of that run rerun on its **full lane** (~228 M pairs), in
   the same image, at the production request (4 cpu, 3 GB), the job's memory sampled every 10 s.

## Selection
BZea5 (batch-1 plate NVS188B BzeaP1, 96 samples incl. 5 checks, 2 lanes as tar members of the two ~1.5 TB plate tars): the
w01 library that failed. Probe lane: `BZea5.<first lane>` (L001).

## Code and checkout
Branch `demux-batch1-fix` pushed to GitHub; on hazel a git worktree `ZEAL/zealgt-demux` of `ZEAL/zealgt` on that branch
(`ZG_REPO`). `ZEAL/zealgt` itself stays on `main` untouched while `cram_gate2_w01r` runs (no pull during a run). The worktree
is removed after the merge, with the user's consent.

## Commands
Gate 1 (after `git worktree add` + checkout of the pushed branch):
```
ssh hazel 'sbatch --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-demux /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-demux/scripts/submit_head_job.sbatch demux_batch1_g1 -profile hazel,short -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-demux/docs/runs/demux_batch1_g1.yml'
```
Probe (after Gate 1's DEMUX tasks succeed; `<task>` = the work dir of DEMUX (BZea5.<L001 lane>) from its trace):
```
ssh hazel 'sbatch /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-demux/scripts/probe_demux_memory.sbatch <task> /share/maize/frodrig4/nf_work/demux_batch1_probe/L001'
```

## Expected resources
- Gate 1: 2 DEMUX (4 cpu, 3 GB, ~1 min each at 13 µs/pair), then stage 2 for 96 small samples (CUTADAPT, FASTQC,
  ALIGN_MARKDUP, SAMTOOLS_STATS, PICARD ~10–20 min floor each, PROVENANCE, REGISTRY): ~30–40 CPU-h, short QOS, ~600 tasks.
- Probe: 1 job, 4 cpu, 3 GB, ≤ 3 h (compute / normal): tar member extraction (~18 GB per read into the probe dir, removed by
  the module's EXIT trap) + cutadapt ~50 min (w01 Gate 1 rate); ~4 CPU-h. Disk peak ≈ 37 GB extracted + ~40 GB demux output
  on /share.

## Done means
1. Gate 1: head job SUCCESS; both DEMUX tasks exit 0 at attempt 1; `demux/` holds only `.fastq.gz` (192 per lane); demux
   QC / registry / CRAMs written to the run's own store; DEMUX trace `peak_rss` noted.
2. Probe: exit 0; **anon memory flat** after start-up (no upward trend over the lane in `memory.tsv`), peak anon well below
   the 3 GB request (≤ 2.4 GB, 0.8×); 192 `.fastq.gz`; cutadapt's pair count = the lane's. Page cache (`file`) is reported
   apart: hazel's sacct MaxRSS counts it, but the kernel reclaims it before an OOM kill; anon is what grew in w01.
3. If the probe passes: the TODO(Gate 2 after containerization) in `conf/hazel.config` / the module is replaced by the measured
   numbers, the PR goes to main, and the batch-1 libraries can enter the Gate 2 waves (w02/w03 re-plan). If it fails: the
   memory trace shows which process grows; nothing larger runs.

## Afterwards
Nothing is removed without consent: `nf_work/demux_batch1_g1/`, `nf_work/demux_batch1_probe/`, the worktree
`ZEAL/zealgt-demux` are listed for cleanup once the results are written up (docs/REQUIREMENTS.md §4, PLAN §6).
