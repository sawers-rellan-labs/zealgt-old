// DEMUX_QC — per-library demultiplexing QC, one file set per library in the store (PLAN §3 row 1, §4 #4: the zealbc1 table
// was overwritten by every pool run). Published to <store>/demux_qc (conf/modules.config: copy, never overwritten);
// READ_DEMULTIPLEXING runs no DEMUX_QC for a library whose table is already stored.
// Reports per-sample assigned pairs and the assignment rate (from the cutadapt JSON), and for the Gate 1 read-structure check
// the base composition of the first bases of the demuxed reads plus the TruSeq read-through share
// (templates/summarize_demux.py, a module template: hashed by content). The cutadapt JSON and text report are kept next to
// the tables. The python version goes into a versions.yml kept next to them in the store (a stored library's record), not an
// `eval` topic tuple: a python module template, and Nextflow 26.04.6 refuses `eval` outputs for non-Bash scripts
// ("Process output of type 'eval' is only allowed with Bash process scripts").
// ext.args = summarize_demux.py options (--check-reads N --positions N).
process DEMUX_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

    input:
    tuple val(meta), path(json, stageAs: 'input/*'), path(report, stageAs: 'input/*'), path(reads, stageAs: 'reads/*'), val(barcodes)
    val subsample

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv")           , emit: tsv
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.summary.tsv")   , emit: summary
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.read_start.tsv"), emit: read_start
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cutadapt.json") , emit: json
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cutadapt.log")  , emit: log
    path "${task.ext.prefix ?: meta.id}.demux_qc.versions.yml"           , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'summarize_demux.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.tsv ${prefix}.summary.tsv ${prefix}.read_start.tsv ${prefix}.cutadapt.json ${prefix}.cutadapt.log

    cat <<-END_VERSIONS > ${prefix}.demux_qc.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
