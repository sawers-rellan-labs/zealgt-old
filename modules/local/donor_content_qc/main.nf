// DONOR_CONTENT_QC — stage 2b (sample_quality_control) donor-content check (PLAN §3 row 2b "Donor-content QC"): per sample the
// ALT read fraction and the share of covered blind-panel sites with ALT reads, against the expectation (12.5 % for BC2S3
// lines, --expected-bc1 for BC1 pools, 0 for B73 controls) and relative to its (donor, role) group; catches B73
// contamination (selfing, seed mix-up) that kinship alone does not separate (templates/estimate_donor_content.py, a module
// template: hashed by content). Runs only when params.qc_panel is set; the blind panel does not exist yet (design §10 item 6),
// so the workflow skips it and the module is tested on a fixture panel. Own environment.yml (python only).
// ext.args = --expected <donor_content_expected> --flag-low <donor_content_flag_low> [--expected-bc1 X --statistic
//            alt_read_fraction|share_sites_alt --flag-relative X --flag-high-b73 X --min-sites N --regions ...].
process DONOR_CONTENT_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(counts, stageAs: 'counts/*')
    path panel
    val sample_map

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.donor_content.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.donor_content_qc.versions.yml"       , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'estimate_donor_content.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.donor_content.tsv

    cat <<-END_VERSIONS > ${prefix}.donor_content_qc.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
