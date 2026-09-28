# Run card: genotype Gate 1, Zx.0540_P3 on chr10:1-20000000

Parameters: `docs/runs/genotype_gate1_zx0540.yml`. Every parameter of the genotype workflow is set there, and each open
decision carries a comment. Design: genotype design §7.4. Testing ladder: `docs/PLAN_pipeline.md` §6.

## Purpose

This is the first real-tool run of the genotype workflow on hazel. It checks three things:

- every entry runs, in order, on one donor and one region with the real tools, under the `short` QOS;
- the outputs agree with the zealbc1 pilot for the same donor and region, except where the design changed something on purpose;
- the measurements that `docs/REQUIREMENTS.md` §4 asks for are recorded.

It runs in two passes, each under its own store key. Pass A turns the 5′ read-start mask off (`mask_read_starts: false`), so
it is comparable with zealbc1, which did not mask. Pass B turns the mask on (design Decision 6). The difference between the
passes is the effect of the mask.

| pass | `genotype_store_key` | `mask_read_starts` | `--outdir` | run ids |
|---|---|---|---|---|
| A | `gate1_zx0540_nomask_r2` | false | `…/results/zealgt/genotype_gate1_zx0540/nomask` | `genotype_gate1_nomask_r2_<entry>` |
| B | `gate1_zx0540_mask` | true | `…/results/zealgt/genotype_gate1_zx0540/mask` | `genotype_gate1_mask_<entry>` |

The first pass-A key, `gate1_zx0540_nomask`, holds sample_quality_control and a failed variant_discovery (job 974146:
ALLELE_COUNTS exit 141, SIGPIPE from `bgzip -dc | head -1` under pipefail). `allele_counts` is in every stage's code hash,
so that key refuses the fixed code by design (review #7), and pass A restarts from entry 1 under `gate1_zx0540_nomask_r2`.

Pass B uses the same card and overrides three values on the command line:
`--genotype_store_key gate1_zx0540_mask --mask_read_starts true --outdir …/mask`.

## Selection

- **Donor:** Zx.0540_P3 (taxon mexicana). It is the zealbc1 pilot donor, so every stage has a zealbc1 result to compare against.
- **BC1 pools (5):** S_2A_3, S_2A_11, S_2B_8, S_2F_1, S_2F_12. They are batch BC1, with mask 2/2 in pass B.
- **Lines (39):** the 40 BC2S3 batch-1 lines PN5_SID464 … PN6_SID505, minus PN6_SID484. Their mask in pass B is 12/0.
- **Excluded:** PN6_SID484, whose sheet row has `include = FALSE` (its CRAM is 1.9 MB, nearly empty).
- **Zero class:** `B73_skim10` only, with mask 12/0 in pass B. It merges 10 batch-1 B73 checks.
- **Not used:** `B73_ERR3288215` is not in `store_genotype_dev`, because its Picard CollectWgsMetrics (~2.5 h) does not fit the
  short QOS. It would need an import with `-profile hazel,normal`. **[OPEN]** Should Gate 1 wait for it? It would then run under a new key.
- **Region:** chr10:1-20,000,000. The RTIGER floor needs at least 1,000 covered own tier-A markers per line (2 × rigidity 500). On
  chr10, Zx.0540_P3 has 40,941 tier-A sites (zealbc1 step 4), about 5-6 k in the first 20 Mb. At ~0.4× about a third of
  those are covered, which gives ~2 k per typical line. A smaller region would exclude most lines.
- **Reference donor:** Zx.0570_P2, through its zealbc1 step-4 table. It is read-only and never re-called. It supplies the gaps
  of Zx.0540_P3 and the k / m of the step-1 prior (`gap_prior_source: other_donors`). With one run donor and no reference
  table, stages 5-6 would have 0 gaps (design §2.4).
- **Coverage λ:** from `sample_qc.tsv` (MEAN_COVERAGE of the markdup-imported CRAMs), reported by the run. The one QC rule is
  `min_coverage` 0.05×.

## Inputs (hazel)

| input | path | status |
|---|---|---|
| CRAM store (read-only) | `/rsstu/users/r/rrellan/BZea/ZEAL/store_genotype_dev/cram_import/` | **being written** (import job 972246, 2026-09-28): all 40 + 44 line CRAMs are there; BC1, `B73_skim10`, CollectWgsMetrics and provenance are not yet. Gate 0 and Gate 1 need all four files per sample |
| genotype sheet | `meta/genotype_dev.csv` (clone) | 96 rows, 94 included; masks inferred (`mask_source` column) |
| reference | `ZEAL/reference/B73.fa` (+ .fai) | ok |
| lowcopy BED | `ZEAL/results/pilot_1B_chr10/union/union_chr10.bed` | ok (chr10 only) |
| reference donor table | `ZEAL/results/bench_zx0570_chr10/step4/Zx.0570_P2.sites.tsv.gz` | ok |
| annotation panels | TIL18, Gigi, schnable (wideseq), mgdb26 chr10 SNP lists | ok (annotation columns only) |
| mappability prior | `ZEAL/store_genotype_dev/reference_inputs/mappability/qcset_til18_v0/mexicana.prior.tsv` (+ README, sha256) | **[STOP-GAP]** written by job 973496; see below |
| blind QC panel | none | **[OPEN]** does not exist (REQUIREMENTS.md:24), so stage 2b uses MIN_COVERAGE only |

**Mappability prior: stop-gap and circular (design §10 item 4, review #11).** No calibrated prior exists yet (PLAN:148-191; the
calibration has not been run). For Gate 1, `mexicana.prior.tsv` is derived once by an agent script:

- source: `ZEAL/results/zealgt_checks/perline_hypotheses_20260926/qc_depth_TIL18.tsv`, run through the step-2 script's `c_prior()`;
- settings: nominal depths 44 / 20, B73 DP ≥ 5, clip 1.5, 31 bins, +1.

The prior is estimated on the same QC set on which the step-2 calls are later judged, so it is circular. It is fine for a
wiring and comparison gate, but not for a result. The card sets `mappability_priors` to that directory. It is part of the
donor_allele_calling settings only. A `flat` rerun (`mappability_prior_mode: flat`, new key) is the
review #11 sensitivity check.

## Commands

For each entry, in the order sample_quality_control, variant_discovery, ancestry_inference, marker_union,
donor_allele_calling, genotype_imputation, reporting, submit the next one only after the previous one has finished:

```
ssh hazel 'git -C /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype pull --ff-only'
ssh hazel 'sbatch --export=ALL,ZG_REPO=/rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype/scripts/submit_head_job.sbatch genotype_gate1_nomask_r2_<entry> -profile hazel,short -params-file /rsstu/users/r/rrellan/BZea/ZEAL/zealgt-genotype/docs/runs/genotype_gate1_zx0540.yml --entry <entry>'
```

For pass B, use run ids `genotype_gate1_mask_<entry>` and add the three overrides above. Before any
real-data run, the code must have passed a CodeRabbit review.

## Outputs

- The keyed store `store_genotype_dev/genotype/<key>/` holds `settings/<stage>.json`, `sample_qc/`, `step4/`, `ancestry/`,
  `union/`, `joint_step4/`, `gap_bc1/`, `gap_lines/`, `donor_alleles/` and `genotypes/` (layout: `docs/output.md`,
  "Genotype workflow").
- Published tables and paintings go to `--outdir`.

## Comparison with the zealbc1 pilot (restricted to chr10:1-20,000,000)

| zealgt output | zealbc1 pilot (`ZEAL/results/…`) | expected differences |
|---|---|---|
| CRISP raw / in-bed / vetoed records | `bench_zx0540_chr10/discovery/Zx.0540_P3/{crisp_all,crisp_inbed,crisp_vetoed}.vcf.gz` (job 949447) | the CRAMs are now duplicate-marked, so there are fewer reads; pass A otherwise has the same inputs and arguments |
| `step4/Zx.0540_P3.chr10_1-20000000.sites.tsv.gz` tiers | `bench_zx0540_chr10/step4/Zx.0540_P3.sites.tsv.gz` | tiers change at weak sites; report a site × tier confusion table and the tier-A overlap |
| witness read count, B73 counts | `…/discovery/Zx.0540_P3/Zx0540_P3_BC2S3_chr10.bam`, `b73_counts.tsv` | one zero-class pool here (`B73_skim10`), two in zealbc1 |
| RTIGER segments | `union_zx0540_zx0570_chr10/rtiger/Zx.0540_P3/rtiger_Zx.0540_P3_r500_chr10.csv` | the region run learns its own parameters from 20 Mb; compare bp agreement of states per line |
| union, step 1, step 2, donor alleles | `union_zx0540_zx0570_chr10/union_chr10.tsv.gz`, `counts/bayes/dhd_bayes_chr10.tsv.gz`, `zealgt_checks/step2_combined_20260928/step2_combined_Zx.0540_P3.tsv` | union alleles should match; step 1 differs where m used Zx.0570_P2's own-table REF (design §10 item 2); step 2 differs by design (review #1 fixes: no promotion at flagged sites or at sites with ALT reads in x = 0 lines) |
| pass B vs pass A | — | the effect of the 5′ mask on tier counts and on `read_position_qc.tsv` |

The comparison is an agent script run as a short-QOS job, not a pipeline module.

## Measurements (REQUIREMENTS §4; the coordinator writes them there after Gate 1)

- the trace for each process: cpus, peak RSS, wall time;
- the size and file count of `work/`;
- the `zg_resources … source=slurm` lines;
- 0 "Creating env" lines in `.nextflow.log`.

## Done means

Both passes finish every entry with exit 0 under the short QOS, the comparison table above is filled in with the differences
explained, and the measurements are recorded.
