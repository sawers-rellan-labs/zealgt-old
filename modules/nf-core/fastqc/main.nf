process FASTQC {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/fastqc:0.12.1--hdfd78af_0'
        : 'quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0'}"

    input:
    tuple val(meta), path(reads, stageAs: '?/*')

    output:
    tuple val(meta), path("*.html"), emit: html
    tuple val(meta), path("*.zip"), emit: zip
    tuple val("${task.process}"), val('fastqc'), eval('fastqc --version | sed "/FastQC v/!d; s/.*v//"'), emit: versions_fastqc, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Make list of old name and new name pairs to use for renaming in the bash while loop
    def old_new_pairs = reads instanceof Path || reads.size() == 1 ? [[reads, "${prefix}.${reads.extension}"]] : reads.withIndex().collect { entry, index -> [entry, "${prefix}_${index + 1}.${entry.extension}"] }
    def rename_to = old_new_pairs*.join(' ').join(' ')
    def renamed_files = old_new_pairs.collect { _old_name, new_name -> new_name }.join(' ')

    // The total amount of allocated RAM by FastQC is equal to the number of threads defined (--threads) time the amount of RAM defined (--memory)
    // https://github.com/s-andrews/FastQC/blob/1faeea0412093224d7f6a07f777fad60a5650795/fastqc#L211-L222
    // zealgt patch (resources only, PLAN §2 rule 4 hash hygiene): threads / memory come from bin/export_slurm_resources.sh at run
    // time (ZG_CPUS, ZG_JAVA_MEM_MB), not from task.cpus / task.memory, so reallocating resources keeps the task hash.
    // --memory = JVM heap / threads, clamped to FastQC's allowed range (100 - 10000) in bash.
    """
    source export_slurm_resources.sh
    fastqc_memory=\$(( ZG_JAVA_MEM_MB / ZG_CPUS ))
    [ "\$fastqc_memory" -le 10000 ] || fastqc_memory=10000
    [ "\$fastqc_memory" -ge 100 ] || fastqc_memory=100

    printf "%s %s\\n" ${rename_to} | while read old_name new_name; do
        [ -f "\${new_name}" ] || ln -s \$old_name \$new_name
    done

    fastqc \\
        ${args} \\
        --threads \${ZG_CPUS} \\
        --memory \${fastqc_memory} \\
        ${renamed_files}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.html
    touch ${prefix}.zip
    """
}
