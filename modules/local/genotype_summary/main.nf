// GENOTYPE_SUMMARY — stage 8 reporting tables of one donor x region (PLAN §3 row 8, §4 #12; design §2.7):
//   genotype_summary.tsv   per line: RTIGER Mb in x = 0 / 1 / 2 over bp, fractions vs the expectation (BC2S2 by default:
//                          HET 1/16, x = 2 3/32), raster counts at the union sites and the no-call share
//   single_locus.tsv       per site: segregation of x vs the expectation (chi-square, 2 df) and the donor allele frequency
//                          vs 12.5 %
//   breakpoint_density.tsv review #12: share of step-2 calls within `breakpoint_window_markers` own tier-A markers of a
//                          RTIGER breakpoint vs elsewhere (the design's BREAKPOINT_DENSITY, folded into this task: it needs
//                          only the segments and DONOR_FOUNDER's call_step, so no second task)
// templates/summarize_genotypes.py (module template, hashed by content). Nothing goes to the store (published only), but
// Nextflow allows `eval` outputs only with bash scripts, so the template writes a versions.yml (as DEMUX_QC). Shared python
// env (envs/process_aliases.tsv GENOTYPE_SUMMARY -> pooled_likelihood_tiers).
// Inputs: RASTERIZE's long table, the RTIGER segments CSV, DONOR_FOUNDER's table, line_qc.tsv (optional: []).
// ext.args = summarize_genotypes.py options: --expectation (bc2s2|bc2s3) --breakpoint-window (500).
process GENOTYPE_SUMMARY {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/../pooled_likelihood_tiers/environment.yml"

    input:
    tuple val(meta), path(genotypes), path(segments), path(donor_alleles), path(line_qc)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.genotype_summary.tsv")  , emit: summary
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.single_locus.tsv")      , emit: single_locus
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.breakpoint_density.tsv"), emit: breakpoint_density
    path "${task.ext.prefix ?: meta.id}.genotype_summary.versions.yml"            , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'summarize_genotypes.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.genotype_summary.tsv ${prefix}.single_locus.tsv ${prefix}.breakpoint_density.tsv

    cat <<-END_VERSIONS > ${prefix}.genotype_summary.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
