// REGISTRY — the demux registry entry of one library (PLAN §0 Task 2): written only when the library's demux QC table and
// ALL its sample CRAMs are there (templates/write_registry.py checks the staged files and refuses otherwise). Published to
// <store>/registry (conf/modules.config: copy, never overwritten): <library>.registry.tsv; the CRAM workflow runs no REGISTRY
// for a library already registered. PIPELINE_INITIALISATION reads <store>/registry/*.registry.tsv plus
// assets/registry_seed.csv (the libraries PLAN §0 lists as demultiplexed) before any DEMUX and refuses a registered library
// unless --force_demux <library>. The template has no options, so there is no task.ext.args; the python version goes into a
// versions.yml kept next to the entry, not an `eval` topic tuple: a python module template, and Nextflow 26.04.6 refuses
// eval outputs for non-Bash scripts ("Process output of type 'eval' is only allowed with Bash process scripts").
process REGISTRY {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

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
