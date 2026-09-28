// DEMUX_QC — per-library demultiplexing QC, one file set per library in the store (PLAN §3 row 1, §4 #4: the zealbc1 table
// was overwritten by every pool run). storeDir <store>/demux_qc (conf/modules.config): a stored library is never redone.
// Reports per-sample assigned pairs and the assignment rate (from the cutadapt JSON), and for the Gate 1 read-structure check
// the base composition of the first bases of the demuxed reads plus the TruSeq read-through share
// (resources/usr/bin/demux_qc.py). The cutadapt JSON and text report are kept next to the tables.
process DEMUX_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(json, stageAs: 'input/*'), path(report, stageAs: 'input/*'), path(reads, stageAs: 'reads/*'), val(barcodes)
    val subsample

    output:
    tuple val(meta), path("${meta.id}.tsv")               , emit: tsv
    tuple val(meta), path("${meta.id}.summary.tsv")       , emit: summary
    tuple val(meta), path("${meta.id}.read_start.tsv")    , emit: read_start
    tuple val(meta), path("${meta.id}.cutadapt.json")     , emit: json
    tuple val(meta), path("${meta.id}.cutadapt.log")      , emit: log
    path "${meta.id}.demux_qc.versions.yml"               , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = "${meta.id}"
    def rows   = barcodes.collect { entry -> "${entry[0]} ${entry[1]} ${entry[2] ?: '-'}" }.join(' ')
    """
    printf 'sample_id\\tbarcode_r1\\tbarcode_r2\\n' > barcodes.tsv
    printf '%s\\t%s\\t%s\\n' ${rows} >> barcodes.tsv
    cp ${json} ${prefix}.cutadapt.json
    cp ${report} ${prefix}.cutadapt.log

    python3 "${moduleDir}/resources/usr/bin/demux_qc.py" \\
        --library ${prefix} \\
        --json ${json} \\
        --barcodes barcodes.tsv \\
        --reads-dir reads \\
        --subsample ${subsample} \\
        ${args}

    cat <<-END_VERSIONS > ${prefix}.demux_qc.versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    stub:
    def prefix = "${meta.id}"
    """
    touch ${prefix}.tsv ${prefix}.summary.tsv ${prefix}.read_start.tsv ${prefix}.cutadapt.json ${prefix}.cutadapt.log

    cat <<-END_VERSIONS > ${prefix}.demux_qc.versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
