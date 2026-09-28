// PROVENANCE — one JSON record per stored CRAM (PLAN §3 "CRAM workflow stop point": source, demux tool, trimming
// parameters, aligner and version, markdup settings, code version). The workflow builds the settings part (meta +
// params, single-line JSON in `record`); this module adds the tool versions of the steps that made the CRAM and its size
// (resources/usr/bin/provenance.py). storeDir <store>/cram (or <store>/cram_import), next to the CRAM (conf/modules.config).
process PROVENANCE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(cram), path(versions, stageAs: 'versions/*'), val(record)

    output:
    tuple val(meta), path("${meta.id}.provenance.json"), emit: json
    path "${meta.id}.provenance.versions.yml"           , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = "${meta.id}"
    """
    cat <<'ZG_EOF' > record.json
    ${record}
    ZG_EOF

    python3 "${moduleDir}/resources/usr/bin/provenance.py" \\
        --record record.json \\
        --cram ${cram} \\
        --versions versions/* \\
        --out ${prefix}.provenance.json

    cat <<-END_VERSIONS > ${prefix}.provenance.versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    stub:
    def prefix = "${meta.id}"
    """
    cat <<'ZG_EOF' > ${prefix}.provenance.json
    ${record}
    ZG_EOF

    cat <<-END_VERSIONS > ${prefix}.provenance.versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
