// REGISTRY — the demux registry entry of one library (PLAN §0 Task 2): written only when the library's demux QC table and
// ALL its sample CRAMs are in the store (resources/usr/bin/registry.py checks and refuses otherwise). storeDir
// <store>/registry (conf/modules.config): <library>.registry.tsv. The workflow reads <store>/registry/*.registry.tsv plus
// assets/registry_seed.csv (the libraries PLAN §0 lists as demultiplexed) before any DEMUX and refuses a registered library
// unless --force-demux <library>.
process REGISTRY {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(demux_qc, stageAs: 'demux_qc/*'), path(crams, stageAs: 'cram/*'), val(samples)
    val store
    val run_id
    val code_version
    val subsample

    output:
    tuple val(meta), path("${meta.id}.registry.tsv"), emit: tsv
    path "${meta.id}.registry.versions.yml"          , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = "${meta.id}"
    """
    python3 "${moduleDir}/resources/usr/bin/registry.py" \\
        --library ${prefix} \\
        --demux-qc ${demux_qc} \\
        --cram-dir cram \\
        --samples ${samples.join(' ')} \\
        --store '${store}' \\
        --run-id '${run_id}' \\
        --code-version '${code_version}' \\
        --subsample ${subsample}

    cat <<-END_VERSIONS > ${prefix}.registry.versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    stub:
    def prefix = "${meta.id}"
    """
    printf 'library\\tsample_id\\n' > ${prefix}.registry.tsv
    printf '${prefix}\\t%s\\n' ${samples.join(' ')} >> ${prefix}.registry.tsv

    cat <<-END_VERSIONS > ${prefix}.registry.versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
