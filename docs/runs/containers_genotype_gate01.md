# Run card: containers Gate 0 + Gate 1, genotype workflow, both mexicana donors (Apptainer vs the stored conda run)

**Purpose.** docs/PLAN_containers.md §5 step 4 for the genotype workflow: show that `-profile hazel,apptainer_hazel` runs
all 7 genotype stages from their images (CRISP and nilHMM from the GHCR images, the rest from Seqera) and gives the same
tables as conda. A bug check (Gate 0/1 judge bugs, not accuracy). Nothing goes into `ZEAL/store`, and nothing is written
into `ZEAL/store_genotype_dev` (read only).

**Code.** Containers: hazel checkout `ZEAL/zealgt-containers`, branch `containers` (the commit that adds this card).
Baseline, **not rerun**: the stored conda run under key `gate1_mex2_port_r1` in `ZEAL/store_genotype_dev` (2026-09-29,
jobs 994256-994418, commit 9377898, 70 files). Its code equals `main` d3b6eb1 except 14 `meta.yml` documentation files
(`git diff --stat 9377898 d3b6eb1` over modules, subworkflows, workflows, conf, nextflow.config, main.nf, bin), so no
fresh conda run is needed.

**Selection.** As `docs/runs/genotype_gate1_mex2.yml` (unchanged, used as the params file): donors Zx.0540_P3 + Zx.0570_P2,
region chr10:1-20000000, B73 control B73_skim10, mask off, every other value that card's. Gate 0: the seven cards of
`docs/runs/gate0/` (Zx.0540_P3 x chr10:1-20 Mb, stub).

**Runs** (head jobs `scripts/submit_head_job.sbatch` with `ZG_REPO=ZEAL/zealgt-containers`, short QOS; one head job per
entry, in stage order, each submitted with `--dependency=afterok` on the previous one; run dirs under
`/share/maize/frodrig4/nf_work/`):

| run_id | profile | params | store / key |
|---|---|---|---|
| `containers_geno_g0_<entry>` x 7 | `hazel,apptainer_hazel,stub` `-stub` | `docs/runs/gate0/genotype_gate0_<entry>.yml` | `nf_work/containers_geno_g0/store_stub`, key `containers_g0` |
| `containers_geno_g1_<entry>` x 7 | `hazel,apptainer_hazel,short` | `docs/runs/genotype_gate1_mex2.yml` | `nf_work/containers_geno_g1/store`, key `gate1_mex2_containers_r1` |

entries in order: sample_quality_control, variant_discovery, ancestry_inference, marker_union, donor_allele_calling,
genotype_imputation, reporting. Each run passes `--workflow genotype --entry <entry> --store <store> --genotype_store_key
<key> --outdir nf_work/<run_dir>/<entry>/outdir`; `cram_store` stays `ZEAL/store_genotype_dev` (read only). Gate 1
starts after Gate 0 succeeds.

**Inputs.** The dev CRAMs of `ZEAL/store_genotype_dev/cram_import`, `ZEAL/reference/B73.fa`, the lowcopy BED, annotation
panels and mappability prior named in the params file. Images: the 18 SIFs in `/share/maize/frodrig4/apptainer/cache`.

**Cost.** The conda chain took ≈ 46 min (7 head jobs, 3-11 min each); Gate 0 a few minutes per entry.

**Done means.**
1. Gate 0: all 7 entries SUCCESS; every task via `apptainer exec`; 0 "Creating env", 0 pulls in the `.nextflow.log`s.
2. Gate 1: all 7 entries SUCCESS; per process the same task counts as the baseline run (its traces in
   `ZEAL/results/zealgt/genotype_gate1_mex2_port/pipeline_info/execution_trace_2026-09-29_*.txt`, one per entry).
3. Same tables: every file under `<store>/genotype/gate1_mex2_containers_r1/` byte-identical to
   `store_genotype_dev/genotype/gate1_mex2_port_r1/`, except files known to embed a run value (the `settings/*.json`
   guards record key, paths and code hash; the compressed step-4 files carry gzip's write time, PR #1 "Open"): those are
   compared after decompression / with the run fields dropped. RTIGER segments and genotype calls must be identical
   (nilHMM v0.3.1 = the code of 248e67e; seeded).
4. Measured: time and peak memory per process vs the baseline traces; CRISP and RTIGER (the GHCR images) in particular.

Any difference in 3 is investigated before the switch (step 5).

**Afterwards.** Nothing is removed without consent; `nf_work/containers_geno_g0/`, `containers_geno_g1/` and the head job
dirs are listed for cleanup 1 (docs/PLAN_cleanup.md) once the comparison is written up.
