process PICARD_COLLECTWGSMETRICS {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/b4/b474c6f12c0502377b95062b75ef4b7778864b1353c7fc1d5a3b1f3b3017fd2e/data'
        : 'community.wave.seqera.io/library/picard:3.5.0--842d4c70c98af9b4'}"

    input:
    tuple val(meta), path(bam), path(bai)
    tuple val(meta2), path(fasta)
    tuple val(meta3), path(fai)
    path intervallist

    output:
    tuple val(meta), path("*_metrics"), emit: metrics
    tuple val("${task.process}"), val('picard'), eval("picard CollectWgsMetrics --version 2>&1 | sed -n 's/.*Version://p'"), topic: versions, emit: versions_picard

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def interval = intervallist ? "--INTERVALS ${intervallist}" : ''
    // zealgt patch (resources only, PLAN §2 rule 4 hash hygiene): threads / memory come from bin/export_slurm_resources.sh at run
    // time (ZG_CPUS, ZG_JAVA_MEM_MB), not from task.cpus / task.memory, so reallocating resources keeps the task hash.
    // -Xmx = ZG_MEM_MB minus the helper's fixed 2048 MB headroom (was task.memory * 0.8).
    """
    source export_slurm_resources.sh
    picard \\
        -Xmx\${ZG_JAVA_MEM_MB}M \\
        CollectWgsMetrics \\
        ${args} \\
        --INPUT ${bam} \\
        --OUTPUT ${prefix}.CollectWgsMetrics.coverage_metrics \\
        --REFERENCE_SEQUENCE ${fasta} \\
        ${interval}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.CollectWgsMetrics.coverage_metrics
    """
}
