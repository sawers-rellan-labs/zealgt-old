// ALIGN_MARKDUP — trimmed read pair -> analysis-ready CRAM, one process with a minibwa + samtools env (PLAN §3 row 2, §4 #1, #1b).
//   minibwa map -x sr -R <read group>  (the RG tag goes on every record; minibwa 0.7 format.c writes RG:Z per record)
//   -> samtools fixmate -m -> sort -> markdup -d 2500 (optical distance for patterned flow cells; duplicates FLAGGED, not removed)
//   -> CRAM against B73 v5, no MAPQ filter, all records kept -> .crai; markdup statistics next to the CRAM.
// storeDir <store>/cram (conf/modules.config): a stored CRAM is never recomputed, whatever changed in this module (PLAN §2 rule 3).
// storeDir does not allow `eval` outputs, so the tool versions go into one versions.yml (one line per tool).
// Threads / memory from bin/export_slurm_resources.sh at run time (hash hygiene): minibwa gets all ZG_CPUS; sort gets up to 4
// threads and (ZG_MEM_MB - 12 GB reserved for the minibwa index and the pipe) split across them, at least 768 MB per thread.
// Sort and markdup temporaries go to TMPDIR (/share, conf/hazel.config) and are removed by samtools.
// ext.args = minibwa map flags (-x sr), ext.args2 = markdup flags (-d 2500), ext.args3 = fixmate, ext.args4 = sort.
process ALIGN_MARKDUP {
    tag "${meta.id}"
    label 'process_high'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(reads), val(read_group)
    tuple val(meta2), path(fasta), path(fai), path(index)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cram"), path("${task.ext.prefix ?: meta.id}.cram.crai"), emit: cram
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.markdup.stats")                                       , emit: markdup_stats
    path "${task.ext.prefix ?: meta.id}.align_markdup.versions.yml"                                            , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def args2  = task.ext.args2 ?: ''
    def args3  = task.ext.args3 ?: ''
    def args4  = task.ext.args4 ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    if (!read_group || !read_group.startsWith('@RG\\tID:')) {
        error("ALIGN_MARKDUP ${prefix}: read_group must be an escaped @RG line ('@RG\\\\tID:...'), got '${read_group}'")
    }
    def (r1, r2) = reads
    """
    source export_slurm_resources.sh

    sort_threads=\$(( ZG_CPUS < 4 ? ZG_CPUS : 4 ))
    sort_mem_mb=\$(( (ZG_MEM_MB - 12288) / sort_threads ))
    [ "\$sort_mem_mb" -ge 768 ] || sort_mem_mb=768
    tmp="\${TMPDIR:-.}/${prefix}.align_markdup.\$\$"
    mkdir -p "\$tmp"
    echo "align_markdup sort_threads=\$sort_threads sort_mem_mb=\$sort_mem_mb tmp=\$tmp" >&2

    minibwa map \\
        -t "\$ZG_CPUS" \\
        ${args} \\
        -R '${read_group}' \\
        ${fasta} \\
        ${r1} ${r2} \\
    | samtools fixmate -@ 2 -m -u ${args3} - - \\
    | samtools sort -@ "\$sort_threads" -m "\${sort_mem_mb}M" -u -T "\$tmp/sort" ${args4} - \\
    | samtools markdup \\
        -@ 2 \\
        ${args2} \\
        -f ${prefix}.markdup.stats \\
        -T "\$tmp/markdup" \\
        --reference ${fasta} \\
        -O cram \\
        - ${prefix}.cram

    samtools index -@ "\$ZG_CPUS" ${prefix}.cram
    rmdir "\$tmp" 2>/dev/null || true

    cat <<-END_VERSIONS > ${prefix}.align_markdup.versions.yml
    "${task.process}":
        minibwa: \$(minibwa version 2>&1 | head -1)
        samtools: \$(samtools version | sed '1!d; s/.* //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the environment.yml pins (the tools are not run in a stub).
    """
    touch ${prefix}.cram ${prefix}.cram.crai ${prefix}.markdup.stats

    cat <<-END_VERSIONS > ${prefix}.align_markdup.versions.yml
    "${task.process}":
        minibwa: 0.7-r421
        samtools: 1.21
    END_VERSIONS
    """
}
