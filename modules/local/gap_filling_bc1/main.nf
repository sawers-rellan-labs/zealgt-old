// GAP_FILLING_BC1 — stage 6 step 1 (PLAN "Stage 6 — two-step gap filling", step 1; math supplement Eq. S4.1, S5.3; design
// §2.4-2.5), one donor set x region: every run donor's allele at every non-multiallelic union site from its BC1 reads.
// own -> ALT; gap -> REF if LLR <= -4 and pooled depth >= 12 (REF from the donor's own reads only); ALT if
// LLR + logit(pi) >= logit(gap_alt_posterior) (log-odds scale, full precision) and not flagged hidepth / af_gt_half; else NA.
// pi from `gap_prior_source` (other_donors: Eq. S5.3 over the other run donors + the union's reference donors, scope all |
// same_taxon; fixed; mu_only). Rewrite of the maths of zealbc1 PHG/bin/dhd_bayes.py (templates/fill_gaps_bc1.py).
// A donor with 0 gaps is logged as `WARN ... 0 gap sites`; a run without other donors uses pi = mu_d and says so
// (summary prior_source_used), no special case.
// Inputs: the union (MARKER_UNION) and the JOINT_POOLED_LIKELIHOOD per-donor tables <donor>.<region>.sites.tsv.gz (matched to
// `donors` by name; columns chrom pos ref alt n a tier flags LLR, plus n_pools_alt n0 a0 eps logodds when present).
// published to <store>/genotype/<key>/gap_bc1 (conf/genotype_modules.config) -> versions.yml (a module template: `eval` outputs need a Bash script).
// Own environment.yml (python only).
// ext.args = fill_gaps_bc1.py options: --gap-alt-posterior (0.999) --gap-prior-w (2) --gap-prior-scope (all|same_taxon)
// --gap-prior-source (other_donors|fixed|mu_only) --gap-prior-fixed (0.5) --ref-llr (-4) --ref-min-depth (12)
// --tier-prior (0.5; the step-4 prior, to recover the full-precision LLR from logodds) --block-flags (hidepth,af_gt_half).
process GAP_FILLING_BC1 {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/fa/fa07e248b1e370d7821404c2c9b042d508e30e5147fa2509c4d58f8f103ebaee/data'
        : 'community.wave.seqera.io/library/python_gzip:6ffdc9aac79f425a'}"

    input:
    tuple val(meta), path(union), path(joint_tables, stageAs: 'joint/*')
    val donors
    val donor_taxa

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv.gz")     , emit: calls
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.summary.tsv"), emit: summary
    path "${task.ext.prefix ?: meta.id}.gap_filling_bc1.versions.yml" , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'fill_gaps_bc1.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf "" | gzip -n > ${prefix}.tsv.gz
    touch ${prefix}.summary.tsv

    cat <<-END_VERSIONS > ${prefix}.gap_filling_bc1.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
