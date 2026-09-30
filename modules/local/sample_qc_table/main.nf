// SAMPLE_QC_TABLE — stage 2b (sample_quality_control) decision table (PLAN §3 row 2b): joins MIN_COVERAGE with the optional
// panel tables (COVERAGE_QC, RELATEDNESS_QC, DONOR_CONTENT_QC) into one sample_qc.tsv row per cohort sample: pass, reasons,
// notes and the main numbers. Discovery and every caller read it (samples with pass = false are removed by a join in the
// workflow). The panel tables are optional inputs (pass [] when params.qc_panel is not set: the blind panel does not exist
// yet, design §10 item 6); then panel_qc = not_run and only MIN_COVERAGE decides (the Gate 1 path MIN_COVERAGE ->
// SAMPLE_QC_TABLE). templates/write_sample_qc.py is a module template (hashed by content). Own environment.yml (python only).
// The python version goes into a versions.yml (a module template: `eval` outputs need a Bash script); outputs
// published to <store>/genotype/<key>/sample_qc (conf/genotype_modules.config).
// ext.args = --fail-on relatedness,donor_content (params.sample_qc_fail_on; panel_coverage may be added).
process SAMPLE_QC_TABLE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(min_coverage), path(panel_coverage), path(relatedness), path(donor_content)
    val sample_map

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.sample_qc.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.sample_qc_table.versions.yml"    , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'write_sample_qc.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.sample_qc.tsv

    cat <<-END_VERSIONS > ${prefix}.sample_qc_table.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
