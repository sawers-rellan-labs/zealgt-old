process SAMTOOLS_STATS {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/e9/e994bf4eb3731150511a14f5706b7bdfd64df1b6d40898fff334286c027e0859/data'
        : 'community.wave.seqera.io/library/htslib_samtools:1.24--d697cfb9dce007cd'}"

    input:
    tuple val(meta), path(input), path(input_index)
    tuple val(meta2), path(fasta), path(fai)

    output:
    tuple val(meta), path("*.stats"), emit: stats
    tuple val("${task.process}"), val('samtools'), eval('samtools version | sed "1!d;s/.* //"'), emit: versions_samtools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def reference = fasta ? "--reference ${fasta}" : ""
    // zealgt patch (resources only, PLAN §2 rule 4 hash hygiene): threads / memory come from bin/export_slurm_resources.sh at run
    // time (ZG_CPUS, ZG_JAVA_MEM_MB), not from task.cpus / task.memory, so reallocating resources keeps the task hash.
    """
    source export_slurm_resources.sh
    samtools \\
        stats \\
        ${args} \\
        --threads \${ZG_CPUS} \\
        ${reference} \\
        ${input} \\
        > ${prefix}.stats
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.stats
    """
}
