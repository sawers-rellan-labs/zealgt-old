# CodeRabbit log: genotype branch (review agent, 2026-09-28)

CLI 0.7.6 (free plan: 150 files per review, 3 reviews per window). Merge base with origin/main: 21efa02.
Driver scripts: agent/20260928_101500_run_coderabbit_genotype.sh (plain `--committed --base-commit`),
agent/20260928_102500_run_coderabbit_split.sh (round 1 split).

## Round 1: base 21efa02, head 2627bf0 (fixes a-d committed), split in three groups
`coderabbit review --committed --base-commit 21efa02 --agent` on the worktree refused the diff: 249 files, limit 150
(raw: agent/20260928_090049_coderabbit_genotype_run1.txt). The split script builds, in a scratch clone (never the worktree),
one synthetic commit per group on top of 21efa02 that holds exactly that group's files at the head, and reviews it with the
same command. Every changed file of 21efa02..2627bf0 is in exactly one group.

| group | files | reviewed content | findings | raw |
|---|---|---|---|---|
| 1 | 140: stage 2b-4 modules (allele_counts coverage_qc crisp donor_content_qc line_marker_qc mask_read_starts min_coverage pooled_likelihood_tiers region_bed relatedness_qc rtiger rtiger_markers sample_qc_table witness_pool witness_veto), modules/nf-core/bcftools, modules.json | 2627bf0 | 3 | agent/20260928_090155_coderabbit_genotype_run1_group1.txt |
| 2 | 116: stage 5-8 modules (chromosome_painting donor_founder gap_filling_bc1 gap_filling_lines genotype_summary marker_union rasterize read_position_qc), subworkflows/ | 2627bf0 | 3 | agent/20260928_090715_coderabbit_genotype_run1_group2.txt |
| 3 | 88: tests docs conf meta envs workflows scripts nextflow.config nextflow_schema.json main.nf CITATIONS.md assets .nf-core.yml .gitignore | 1cd6966 (these files as at 2627bf0; 45d2041 / 1cd6966 touch only group-1/2 files) | 0 | agent/20260928_091113_coderabbit_genotype_run1_group3.txt |

| # | sev | file | decision |
|---|---|---|---|
| 1.1 | major | modules/local/relatedness_qc/templates/estimate_relatedness.py:213 | **fixed** (1cd6966): a panel site with no reads in any mapped sample still got an empty `counts` entry, so `p = sum([]) / 0` raised ZeroDivisionError (likely on skim data); such a site is now skipped |
| 1.2 | minor | modules/local/line_marker_qc/templates/filter_line_markers.py:151 | **fixed** (1cd6966): with no markers `all()` over no contigs passed every line and line_qc.tsv had no rows; now one row per line, contig `.`, `line_pass false`, reason `no_markers`; new real test "no markers" |
| 1.3 | major | modules/local/witness_pool/main.nf:42 | **rejected**: `samtools addreplacerg -m overwrite_all -r ...` replaces the header @RG lines too. The real test merges p1.bam (`@RG ID:p1`) and p2.bam (`@RG ID:p2`) and asserts the output header is exactly `@RG ID:Zx0540_P3_BC2S3 ...` (passes, local samtools 1.23; env pins 1.21). The script also exits non-zero unless the header has exactly one @RG with the witness ID, so a samtools that kept old headers would stop the task, not pass silently |
| 2.1 | major | modules/local/read_position_qc/templates/count_alt_by_cycle.py:143 | **fixed** (a503613): SystemExit raised in a Pool worker is a BaseException, which `pool.map` does not hand back as a task error; now RuntimeError, caught in the parent and turned into `sys.exit(message)` |
| 2.2 | major | subworkflows/local/utils_nfcore_zealgt_pipeline/genotype_functions.nf:58 | **fixed** (a503613): REGION_BED runs in sample_quality_control and donor_allele_calling but was not in their code hash; MARKER_UNION is not run by donor_allele_calling and was |
| 2.3 | minor | modules/local/read_position_qc/templates/count_alt_by_cycle.py:134 | **fixed** (a503613): the SAM line end stayed on QUAL for a record without optional tags; `line.rstrip(NL)` before the split |

Also fixed after round 1, found by the full local module nf-test run rather than by CodeRabbit: 45d2041 (module tests stale
after WP8's genotype_modules.config: QC modules need `qc_panel` for their ext.when, stub tests expect the ext.prefix names).

## Round 2: base 2627bf0 (last reviewed head), head a503613
First attempt (agent/20260928_091314_coderabbit_genotype_run2.txt): no review, `rate_limit` (3 reviews used, wait 48 min).
Second attempt after the window (agent/20260928_100321_coderabbit_genotype_run2.txt): `coderabbit review --committed
--base-commit 2627bf0 --agent`, head a503613 (commits 45d2041, 1cd6966, a503613; 16 files): **0 findings**.

## Status
Clean at **a503613**. Round 1 covered every file of 21efa02..2627bf0 (three groups), and round 2 covered every change after
that. The genotype code passes the CodeRabbit gate. The commit that adds this log changes only this file.

| round | base | head | findings | action |
|---|---|---|---|---|
| 1 (3 groups) | 21efa02 | 2627bf0 | 6 (3 + 3 + 0) | 5 fixed (1cd6966, a503613), 1 rejected (1.3, reason above) |
| 2 | 2627bf0 | a503613 | 0 | none |

## Round 3 (Gate 1 fix loop): base d570ac7 (last reviewed head + log), head f9416d4
`coderabbit review --committed --base-commit d570ac7 --agent` (2026-09-28, Gate 1 agent): commits 778e55f (ALLELE_COUNTS
header read with `awk 'NR == 1'` instead of `head -1`: SIGPIPE exit 141 under pipefail, job 974146) and f9416d4 (Gate 1
card: pass-A key gate1_zx0540_nomask_r2, mappability_priors set); 3 files: **0 findings**. Clean at **f9416d4**.

| round | base | head | findings | action |
|---|---|---|---|---|
| 3 | d570ac7 | f9416d4 | 0 | none |

## Round 4 (Gate 1 fix loop): base 163bcb7, head be5dbd3
`coderabbit review --committed --base-commit 163bcb7 --agent` (2026-09-28, Gate 1 agent): commits b7877cf (RTIGER: RcppParallel 1 thread, nilHMM threads = ZG_CPUS; nested threads crashed R, job 974290) and be5dbd3 (Gate 1 card: pass-A key gate1_zx0540_nomask_r3); 4 files: **0 findings**. Clean at **be5dbd3**.

| round | base | head | findings | action |
|---|---|---|---|---|
| 4 | 163bcb7 | be5dbd3 | 0 | none |
