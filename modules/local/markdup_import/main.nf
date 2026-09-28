// MARKDUP_IMPORT — the MARK_DUPLICATES + read-group pass for existing CRAMs/BAMs imported from zealbc1 / nilhmm (PLAN §0 Task 2
// bullet 4, §4 #1, #1b): no realignment. One local module in the samtools env of ALIGN_MARKDUP (same samtools as the new CRAMs),
// one pipe, as the measured array 963772 ran it (4 cpu, peak <= 11.4 GB, <= 16 min):
//   samtools addreplacerg -m overwrite_all (RG on every record) -> collate -> fixmate -m -> sort -> markdup -d 2500 -> CRAM + .crai
// Read group, decided from the input HEADER (meta/dev_import.csv's read_groups column is wrong for the bc2s3_realign rows):
//   exactly one @RG line whose SM is the sample -> that line is kept (ID/SM/LB as written) and applied to every record;
//   none or several       -> the sample-sheet read group (input read_group) replaces them (merged pools keep one RG, §4 #1b);
//                            whenever the sheet RG is used, the input's @RG header lines are dropped first (gawk), so no stale
//                            sample remains in the header.
// The inputs keep their zealbc1 MAPQ 20 / -F 0x904 filter (the provenance record says so); reads whose mate was filtered are
// marked as single-end by markdup. Published to <store>/cram_import (conf/modules.config: copy, never overwritten), separate
// from new CRAMs (<store>/cram); the CRAM workflow does not import a sample whose CRAM there is stored and verified.
// Threads / memory from task.cpus / task.memory (standard nf-core; not hashed on Nextflow >= 26.04.6). samtools sort gets
// threads = min(task.cpus, 4) and the bounded share rule of ALIGN_MARKDUP with its own reserve:
//   sort_mem_mb = max(768, floor((task.memory in MB - reserve_mb) x share / threads))
// reserve_mb = params.import_mem_reserve_gb (2 GB: no minibwa index here; view / gawk / addreplacerg / collate / fixmate /
// markdup stream with small buffers) and share = params.align_sort_mem_share (0.75, the same samtools sort, which fills its
// -m x threads budget and overshoots it by ~5-10 %: Gate 2 (gate2_3A), main checkout agent/20260929_032000_align_rss.tsv +
// agent/handover_*_gate2.md). At the 12 GB first attempt: 7.5 GB for sort (was 6 GB, half of memory), >= 3.7 GB for the
// rest. Gate 1, job 969706: (memory - 2 GB) = 10 GB for sort (no share) was OOM-killed at 12 GB. Both params are referenced
// here, so they enter the task hash by value (deliberate re-tunes only). A stage killed by a signal (OOM) makes the task exit with that
// status (zg_pipe_fail: the signal status, 137 preferred over the SIGPIPE 141 it causes upstream, else the first non-zero
// status; errorStrategy retries 130-145 with more memory), so it is retried. The versions go into one versions.yml
// (samtools, gawk), published next to the CRAM: PROVENANCE of an already-stored CRAM reads it from there.
// ext.args = markdup flags (-d 2500), ext.args2 = fixmate, ext.args3 = sort.
process MARKDUP_IMPORT {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(input, stageAs: 'input/*'), path(index, stageAs: 'input/*'), val(read_group)
    tuple val(meta2), path(fasta), path(fai)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cram"), path("${task.ext.prefix ?: meta.id}.cram.crai"), emit: cram
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.markdup.stats")                                       , emit: markdup_stats
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.read_group.txt")                                      , emit: read_group
    path "${task.ext.prefix ?: meta.id}.markdup_import.versions.yml"                                           , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def args2  = task.ext.args2 ?: ''
    def args3  = task.ext.args3 ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def rg     = read_group
    if (!rg || !rg.startsWith('@RG\\tID:')) {
        error("MARKDUP_IMPORT ${prefix}: read_group must be an escaped @RG line ('@RG\\\\tID:...'), got '${rg}'")
    }
    def memory_mb   = task.memory ? task.memory.toMega() : 0
    def threads     = Math.min(task.cpus as int, 4)
    def reserve_mb  = (params.import_mem_reserve_gb.toString().toBigDecimal() * 1024).longValue()
    def share       = params.align_sort_mem_share.toString().toBigDecimal()
    def sort_mem_mb = Math.max(768L, ((memory_mb - reserve_mb) * share).longValue().intdiv(threads))
    """
    threads=${threads}
    sort_mem_mb=${sort_mem_mb}
    echo "markdup_import cpus=${task.cpus} memory_mb=${memory_mb} reserve_mb=${reserve_mb} sort_share=${share} threads=${threads} sort_mem_mb=${sort_mem_mb}" >&2

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
        echo "markdup_import: pipe statuses \$*" >&2
        [ "\$sig" -eq 0 ] || exit "\$sig"
        exit \$(( first ? first : 1 ))
    }
    tmp="\${TMPDIR:-.}/${prefix}.markdup_import.\$\$"
    mkdir -p "\$tmp"

    samtools view -H --reference ${fasta} ${input} > header.sam
    n_rg=0
    header_rg=""
    while IFS= read -r line; do
        case "\$line" in
            @RG*) n_rg=\$(( n_rg + 1 )); header_rg="\$line" ;;
        esac
    done < header.sam
    header_sm=""
    if [ "\$n_rg" -eq 1 ]; then
        case "\$header_rg" in
            *\$'\\t'SM:*) header_sm="\${header_rg#*\$'\\t'SM:}"; header_sm="\${header_sm%%\$'\\t'*}" ;;
        esac
    fi
    if [ "\$n_rg" -eq 1 ] && [ "\$header_sm" = "${prefix}" ]; then
        rg_line="\${header_rg//\$'\\t'/\\\\t}"
        rg_source="header"
    elif [ "\$n_rg" -eq 1 ]; then
        rg_line='${rg}'
        rg_source="sample_sheet (the input header RG has SM:\$header_sm, not ${prefix})"
    else
        rg_line='${rg}'
        rg_source="sample_sheet (input header had \$n_rg @RG lines)"
    fi
    printf 'sample\\t%s\\nsource\\t%s\\nread_group\\t%s\\n' "${prefix}" "\$rg_source" "\$rg_line" > ${prefix}.read_group.txt
    echo "markdup_import threads=\$threads sort_mem_mb=\$sort_mem_mb rg_source=\$rg_source rg=\$rg_line" >&2

    add_rg() {
        if [ "\$n_rg" -gt 0 ] && [ "\$rg_source" != "header" ]; then
            samtools view -h --reference ${fasta} ${input} \\
            | gawk '!/^@RG\t/' \\
            | samtools addreplacerg -@ "\$threads" -m overwrite_all -w -r "\$rg_line" -O BAM --output-fmt-option level=0 -o - -
        else
            samtools addreplacerg -@ "\$threads" -m overwrite_all -w -r "\$rg_line" --reference ${fasta} -O BAM --output-fmt-option level=0 -o - ${input}
        fi
    }

    add_rg \\
    | samtools collate -@ "\$threads" -O -u - "\$tmp/collate" \\
    | samtools fixmate -@ "\$threads" -m -u ${args2} - - \\
    | samtools sort -@ "\$threads" -m "\${sort_mem_mb}M" -u -T "\$tmp/sort" ${args3} - \\
    | samtools markdup \\
        -@ "\$threads" \\
        ${args} \\
        -f ${prefix}.markdup.stats \\
        -T "\$tmp/markdup" \\
        --reference ${fasta} \\
        -O cram \\
        - ${prefix}.cram \\
    || zg_pipe_fail "\${PIPESTATUS[@]}"

    samtools index -@ "\$threads" ${prefix}.cram
    rm -f header.sam
    rmdir "\$tmp" 2>/dev/null || true

    cat <<-END_VERSIONS > ${prefix}.markdup_import.versions.yml
    "${task.process}":
        samtools: \$(samtools version | sed '1!d; s/.* //')
        gawk: \$(gawk --version | sed '1!d; s/GNU Awk //; s/,.*//')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the environment.yml pins (the tools are not run in a stub). The stub CRAM is the 38-byte CRAM 3 EOF
    // container, so a stored stub CRAM passes the store check (zgCramEofOk) like a real one.
    """
    printf '\\x0f\\x00\\x00\\x00\\xff\\xff\\xff\\xff\\x0f\\xe0\\x45\\x4f\\x46\\x00\\x00\\x00\\x00\\x01\\x00\\x05\\xbd\\xd9\\x4f\\x00\\x01\\x00\\x06\\x06\\x01\\x00\\x01\\x00\\x01\\x00\\xee\\x63\\x01\\x4b' > ${prefix}.cram
    touch ${prefix}.cram.crai ${prefix}.markdup.stats ${prefix}.read_group.txt

    cat <<-END_VERSIONS > ${prefix}.markdup_import.versions.yml
    "${task.process}":
        samtools: 1.21
        gawk: 5.4.1
    END_VERSIONS
    """
}
