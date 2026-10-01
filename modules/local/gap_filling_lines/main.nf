// GAP_FILLING_LINES — stage 6 step 2, the per-line ALT rescue (PLAN "Stage 6 — two-step gap filling" step 2, additive rule
// decided 2026-09-28; design §2.5), one donor x region, at the gaps step 1 left missing:
//   logodds = logit(pi) + LLR_BC1 + LLR_lines >= logit(gap_alt_posterior) -> ALT; never REF.
// LLR_lines from the donor's lines split by RTIGER ancestry (x = 0 / 1 / 2), donor-copy mappability c summed out under the
// taxon prior, depth ~ Pois(k_s lambda_i [(1 - x/2) + (x/2) c]). Review #1 fixes: (a) a site step 1 blocked for a step-4 flag
// (hidepth / af_gt_half) is never promoted (call blocked_flag); (b) reads of x = 0 lines are zero-class reads:
// eps_s = (a0 + a_x0 + alpha) / (n0 + n_x0 + beta) in both hypotheses, and ALT in x = 0 lines significantly above the
// zero-class eps (binomial p < b73_lines_alt_p) -> blocked_b73_lines. The rejected false-allele hypothesis is not carried.
// templates/fill_gaps_lines.py (module template, hashed by content). Lines excluded by LINE_MARKER_QC are not used.
// Inputs: the set's GAP_FILLING_BC1 table (carries LLR, prior, flags, n0, a0 of every donor; the donor is picked by `donor`),
// the donor's LINE_UNION_COUNTS table (bcftools query -H AD at the union sites; sample names = line ids), its RTIGER segments
// CSV and line_qc.tsv (stage-4 store; line_qc optional: []), and the mappability prior <taxon>.prior.tsv (columns c, weight;
// optional [] only with --mappability-prior-mode flat).
// published to <outdir>/genotype/<key>/gap_lines/<set> (conf/genotype_modules.config) -> versions.yml (a module template: `eval` outputs need a Bash script).
// Own environment.yml (python only).
// ext.args = fill_gaps_lines.py options: --gap-alt-posterior (0.999) --eps-prior-alpha (1) --eps-prior-beta (200)
// --b73-lines-alt-p (0.01) --b73-lines-min-alt (1) --ks-floor (0.02) --mappability-prior-mode (taxon|flat) --c-grid-max (1.5) --c-grid-step (0.05)
// --lambda-sites (all|candidates) --block-flags (hidepth,af_gt_half).
process GAP_FILLING_LINES {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/fa/fa07e248b1e370d7821404c2c9b042d508e30e5147fa2509c4d58f8f103ebaee/data'
        : 'community.wave.seqera.io/library/python_gzip:6ffdc9aac79f425a'}"

    input:
    tuple val(meta), path(gap_bc1), path(lines_counts), path(segments), path(line_qc), path(c_prior)
    val donor

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv.gz")     , emit: calls
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.summary.tsv"), emit: summary
    path "${task.ext.prefix ?: meta.id}.gap_filling_lines.versions.yml", emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'fill_gaps_lines.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf "" | gzip -n > ${prefix}.tsv.gz
    touch ${prefix}.summary.tsv

    cat <<-END_VERSIONS > ${prefix}.gap_filling_lines.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
