// PROVENANCE — one JSON record per stored CRAM (PLAN §3 "CRAM workflow stop point": source, demux tool, trimming
// parameters, aligner and version, markdup settings, code version). The pipeline builds the settings part
// (zgProvenanceRecord in subworkflows/local/utils_nfcore_zealgt_pipeline; single-line JSON in `record`); this module adds the
// versions.yml files of the steps that made the CRAM and its size (templates/write_provenance.py, a module template: hashed
// by content). Published to <store>/cram (or <store>/cram_import), next to the CRAM (conf/modules.config: copy, never
// overwritten); CRAM_QC_PROVENANCE runs no PROVENANCE for a sample whose record is already stored. The template has no
// options, so there is no task.ext.args; the python version goes into a versions.yml kept next to the record, not an
// `eval` topic tuple: a python module template, and Nextflow 26.04.6 refuses `eval` outputs for non-Bash scripts
// ("Process output of type 'eval' is only allowed with Bash process scripts").
process PROVENANCE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(cram), path(versions, stageAs: 'versions/*'), val(record)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.provenance.json"), emit: json
    path "${task.ext.prefix ?: meta.id}.provenance.versions.yml"           , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'write_provenance.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    cat <<'ZG_EOF' > ${prefix}.provenance.json
    ${record}
    ZG_EOF

    cat <<-END_VERSIONS > ${prefix}.provenance.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
