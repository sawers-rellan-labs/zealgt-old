// COVERAGE_QC — stage 2b (sample_quality_control) panel coverage report (PLAN §3 row 2b "Coverage QC"; zealhmm
// scripts/zeal_paired_cohort_coverage_qc.R): covered blind-panel markers (>= 1 read) per sample x chromosome from the
// QC_PANEL_COUNTS tables, with the counts below --min-markers (params.panel_min_markers) and below 10 / 100 reported.
// It reports only: the line exclusion by covered markers is applied in ancestry_inference on the donor's own tier-A sites
// (LINE_MARKER_QC; design §10 item 5). Runs only when params.qc_panel is set (the blind panel does not exist yet, design
// §10 item 6; the workflow skips the process otherwise). templates/count_panel_coverage.py is a module template (hashed by
// content). Own environment.yml (python only).
// ext.args = --min-markers N --report-at 10,100 [--regions chr10:1-20000000,...].
process COVERAGE_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(counts, stageAs: 'counts/*')
    path panel
    val sample_map

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.panel_coverage.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.coverage_qc.versions.yml"             , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'count_panel_coverage.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.panel_coverage.tsv

    cat <<-END_VERSIONS > ${prefix}.coverage_qc.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
