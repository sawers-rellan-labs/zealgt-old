// ALIGN_MARKDUP — trimmed read pair -> analysis-ready CRAM, one process with a minibwa + samtools env (PLAN §3 row 2, §4 #1, #1b).
//   minibwa map -x sr -R <read group>  (the RG tag goes on every record; minibwa 0.7 format.c writes RG:Z per record)
//   -> samtools fixmate -m -> sort -> markdup -d 2500 (optical distance for patterned flow cells; duplicates FLAGGED, not removed)
//   -> CRAM against B73 v5, no MAPQ filter, all records kept -> .crai; markdup statistics next to the CRAM.
// Published to <outdir>/cram (conf/modules.config: copy, never overwritten); the CRAM workflow does not align a sample whose
// CRAM is stored and verified (zgIsStored), whatever changed in this module (PLAN §2 rule 3). The tool versions go into one
// versions.yml (one line per tool), published next to the CRAM: PROVENANCE of an already-stored CRAM reads it from there.
// Threads / memory from task.cpus / task.memory, the standard nf-core way (Nextflow >= 26.04.6 does not hash the resource
// values interpolated into the script, nextflow-cache skill). minibwa gets all task.cpus; samtools sort gets
// sort_threads = min(task.cpus, 4) threads and an explicit per-thread -m, a bounded share of what is left of task.memory:
//   sort_mem_mb = max(768, floor((task.memory in MB - reserve_mb) x share / sort_threads))
// reserve_mb = params.align_mem_reserve_gb (28 GiB: minibwa + fixmate M, ~10 GiB unspilled, 17-22.5 GiB once sort spills,
// design 26 GiB, plus headroom) and share = params.align_sort_mem_share (0.75: samtools sort grows to its full -m x threads
// budget, RSS ~1.0 x it; main checkout agent/20260928_204500_align_memory_calibration.md). Gate 2 (gate2_3A and its relaunch;
// main checkout agent/20260929_032000_align_rss.tsv + agent/handover_*_gate2.md): the old (memory - 12 GiB) / 4 rule made
// every attempt (24 / 48 / 72 GB) OOM, and 6 of 8 first attempts at 24 GB with reserve 16 still OOM'd (minibwa growth).
// Model: peak = M + 1.0 x sort budget; at 48 GB: sort 4 x 3840 MB (15 GiB), peak ~41 GiB (hazel kills at 95 % = 45.6 GiB). Both params are referenced here, so they enter the task
// hash by value: change them only with a deliberate re-tune. The chosen values are logged to stderr. The first-attempt
// memory is params.align_memory_gb (conf/hazel.config).
// A pipe stage killed by a signal (OOM) makes the task exit with that status (zg_pipe_fail), so the memory-escalation retry
// of conf/hazel.config actually fires (Gate 1: an OOM-killed sort otherwise surfaced as markdup's exit 1). zg_pipe_fail
// exits with the pipe's signal status (137 = OOM kill preferred over the SIGPIPE 141 it causes upstream; errorStrategy
// retries 130-145 with more memory), else with its first non-zero status; without it, pipefail + set -e report the last
// stage's error (markdup: exit 1).
// Sort and markdup temporaries go to TMPDIR (/share, conf/hazel.config) and are removed by samtools.
// ext.args = minibwa map flags (-x sr), ext.args2 = markdup flags (-d 2500), ext.args3 = fixmate, ext.args4 = sort.
process ALIGN_MARKDUP {
    tag "${meta.id}"
    label 'process_high'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/9e/9e2e098dd3916f58f277db74a690926056acb1afa1734a518afdd733ac20805b/data'
        : 'community.wave.seqera.io/library/minibwa_samtools_htslib:d284993f5ca26fd3'}"

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
    def memory_mb    = task.memory ? task.memory.toMega() : 0
    def sort_threads = Math.min(task.cpus as int, 4)
    def reserve_mb   = (params.align_mem_reserve_gb.toString().toBigDecimal() * 1024).longValue()
    def share        = params.align_sort_mem_share.toString().toBigDecimal()
    def sort_mem_mb  = Math.max(768L, ((memory_mb - reserve_mb) * share).longValue().intdiv(sort_threads))
    """
    tmp="\${TMPDIR:-.}/${prefix}.align_markdup.\$\$"
    mkdir -p "\$tmp"
    echo "align_markdup cpus=${task.cpus} memory_mb=${memory_mb} reserve_mb=${reserve_mb} sort_share=${share} sort_threads=${sort_threads} sort_mem_mb=${sort_mem_mb} tmp=\$tmp" >&2

    zg_pipe_fail() {
        local s sig=0 first=0
        for s in "\$@"; do
            if [ "\$s" -eq 137 ]; then
                sig=137
            elif [ "\$s" -gt 128 ] && [ "\$sig" -eq 0 ]; then
                sig=\$s
            fi
            [ "\$first" -ne 0 ] || first=\$s
        done
        echo "align_markdup: pipe statuses \$*" >&2
        [ "\$sig" -eq 0 ] || exit "\$sig"
        exit \$(( first ? first : 1 ))
    }

    minibwa map \\
        -t ${task.cpus} \\
        ${args} \\
        -R '${read_group}' \\
        ${fasta} \\
        ${r1} ${r2} \\
    | samtools fixmate -@ 2 -m -u ${args3} - - \\
    | samtools sort -@ ${sort_threads} -m ${sort_mem_mb}M -u -T "\$tmp/sort" ${args4} - \\
    | samtools markdup \\
        -@ 2 \\
        ${args2} \\
        -f ${prefix}.markdup.stats \\
        -T "\$tmp/markdup" \\
        --reference ${fasta} \\
        -O cram \\
        - ${prefix}.cram \\
    || zg_pipe_fail "\${PIPESTATUS[@]}"

    samtools index -@ ${task.cpus} ${prefix}.cram
    rmdir "\$tmp" 2>/dev/null || true

    cat <<-END_VERSIONS > ${prefix}.align_markdup.versions.yml
    "${task.process}":
        minibwa: \$(minibwa version 2>&1 | head -1)
        samtools: \$(samtools version | sed '1!d; s/.* //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the environment.yml pins (the tools are not run in a stub). The stub CRAM is the 38-byte CRAM 3 EOF
    // container, so a stored stub CRAM passes the store check (zgCramEofOk) like a real one.
    """
    printf '\\x0f\\x00\\x00\\x00\\xff\\xff\\xff\\xff\\x0f\\xe0\\x45\\x4f\\x46\\x00\\x00\\x00\\x00\\x01\\x00\\x05\\xbd\\xd9\\x4f\\x00\\x01\\x00\\x06\\x06\\x01\\x00\\x01\\x00\\x01\\x00\\xee\\x63\\x01\\x4b' > ${prefix}.cram
    touch ${prefix}.cram.crai ${prefix}.markdup.stats

    cat <<-END_VERSIONS > ${prefix}.align_markdup.versions.yml
    "${task.process}":
        minibwa: 0.7-r421
        samtools: 1.21
    END_VERSIONS
    """
}
