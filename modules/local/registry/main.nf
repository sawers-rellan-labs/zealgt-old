// REGISTRY — the demux registry entry of one library (PLAN §0 Task 2): written only when the library's demux QC table and
// ALL its sample CRAMs are in the store (templates/write_registry.py checks and refuses otherwise). storeDir
// <store>/registry (conf/modules.config): <library>.registry.tsv. PIPELINE_INITIALISATION reads <store>/registry/*.registry.tsv
// plus assets/registry_seed.csv (the libraries PLAN §0 lists as demultiplexed) before any DEMUX and refuses a registered
// library unless --force_demux <library>. The template has no options, so there is no task.ext.args; storeDir forbids `eval`
// outputs, so the python version goes into a versions.yml.
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
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.registry.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.registry.versions.yml"          , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'write_registry.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf 'library\\tsample_id\\n' > ${prefix}.registry.tsv
    printf '${prefix}\\t%s\\n' ${samples.join(' ')} >> ${prefix}.registry.tsv

    cat <<-END_VERSIONS > ${prefix}.registry.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
