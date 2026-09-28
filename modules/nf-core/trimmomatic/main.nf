process TRIMMOMATIC {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/trimmomatic:0.39--hdfd78af_2':
        'quay.io/biocontainers/trimmomatic:0.39--hdfd78af_2' }"

    input:
    tuple val(meta), path(reads)
    path adapters // zealgt patch: adapter FASTA staged (ILLUMINACLIP in ext.args, conf/modules.config)

    output:
    tuple val(meta), path("*.paired.trim*.fastq.gz")   , emit: trimmed_reads
    tuple val(meta), path("*.unpaired.trim_*.fastq.gz"), emit: unpaired_reads, optional:true
    tuple val(meta), path("*_trim.log")                , emit: trim_log
    tuple val(meta), path("*_out.log")                 , emit: out_log
    tuple val(meta), path("*.summary")                 , emit: summary
    tuple val("${task.process}"), val('trimmomatic'), eval("trimmomatic -version"), topic: versions, emit: versions_trimmomatic

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def trimmed = meta.single_end ? "SE" : "PE"
    def output = meta.single_end ?
        "${prefix}.SE.paired.trim.fastq.gz" // HACK to avoid unpaired and paired in the trimmed_reads output
        : "${prefix}.paired.trim_1.fastq.gz ${prefix}.unpaired.trim_1.fastq.gz ${prefix}.paired.trim_2.fastq.gz ${prefix}.unpaired.trim_2.fastq.gz"
    def qual_trim = task.ext.args2 ?: ''
    // zealgt patch (resources only, PLAN §2 rule 4 hash hygiene): threads / memory come from bin/export_slurm_resources.sh at run
    // time (ZG_CPUS, ZG_JAVA_MEM_MB), not from task.cpus / task.memory, so reallocating resources keeps the task hash.
    // The bioconda wrapper otherwise starts the JVM with its default -Xmx1g.
    // zealgt patch: the adapter FASTA is an input (staged, so no absolute path in ext.args or the script).
    """
    source export_slurm_resources.sh
    trimmomatic \\
        -Xmx\${ZG_JAVA_MEM_MB}m \\
        $trimmed \\
        -threads \${ZG_CPUS} \\
        -trimlog ${prefix}_trim.log \\
        -summary ${prefix}.summary \\
        $reads \\
        $output \\
        $qual_trim \\
        $args 2>| >(tee ${prefix}_out.log >&2)
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"

    if (meta.single_end) {
        output_command = "echo '' | gzip > ${prefix}.SE.paired.trim.fastq.gz"
    } else {
        output_command  = "echo '' | gzip > ${prefix}.paired.trim_1.fastq.gz\n"
        output_command += "echo '' | gzip > ${prefix}.paired.trim_2.fastq.gz\n"
        output_command += "echo '' | gzip > ${prefix}.unpaired.trim_1.fastq.gz\n"
        output_command += "echo '' | gzip > ${prefix}.unpaired.trim_2.fastq.gz"
    }

    """
    $output_command
    touch ${prefix}.summary
    touch ${prefix}_trim.log
    touch ${prefix}_out.log
    """

}
