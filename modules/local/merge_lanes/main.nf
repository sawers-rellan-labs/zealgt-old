// MERGE_LANES — one library: join each sample's per-lane DEMUX outputs into one FASTQ pair (PLAN §3 row 1).
//
// DEMUX runs once per library x lane and writes <sample>.<lane>_R{1,2}.fastq.gz; this task concatenates the lane files of
// each sample, in lane-name order, into demux/<sample>_R{1,2}.fastq.gz. Plain `cat` of the gzip files: a multi-member gzip
// is a valid gzip file (RFC 1952; Trimmomatic, FastQC, pigz and python's gzip read it). Nothing is recompressed.
// Every sample must have exactly n_lanes (input) files per read (DEMUX writes an empty gzip for a sample without reads).
// No own environment.yml: it runs in the DEMUX env (coreutils cat; envs/process_aliases.tsv maps MERGE_LANES -> demux), so no
// new hazel prefix is built. coreutils is pinned there and not reported. task.cpus files are written at a time.
process MERGE_LANES {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/../demux/environment.yml"

    input:
    tuple val(meta), path(reads, stageAs: 'lanes/*'), val(barcodes), val(n_lanes)

    output:
    tuple val(meta), path("demux/*_R{1,2}.fastq.gz"), emit: reads

    when:
    task.ext.when == null || task.ext.when

    script:
    def samples = barcodes.collect { entry -> entry[0] }.join(' ')
    """
    mkdir demux

    for s in ${samples}; do
        for r in R1 R2; do
            set -- lanes/"\${s}".*_"\${r}".fastq.gz
            [ -e "\$1" ] && [ "\$#" -eq ${n_lanes} ] || { echo "MERGE_LANES ${meta.id}: \${s} \${r}: \$# lane files, expected ${n_lanes}" >&2; exit 1; }
        done
    done

    pids=""
    n=0
    for s in ${samples}; do
        for r in R1 R2; do
            cat lanes/"\${s}".*_"\${r}".fastq.gz > demux/"\${s}_\${r}".fastq.gz &
            pids="\$pids \$!"
            n=\$(( n + 1 ))
            if [ "\$n" -ge ${task.cpus} ]; then
                for p in \$pids; do wait "\$p"; done
                pids=""
                n=0
            fi
        done
    done
    for p in \$pids; do wait "\$p"; done
    """

    stub:
    def touch_reads = barcodes.collect { entry -> "echo '' | gzip > demux/${entry[0]}_R1.fastq.gz; echo '' | gzip > demux/${entry[0]}_R2.fastq.gz" }.join('; ')
    """
    mkdir demux
    ${touch_reads}
    """
}
