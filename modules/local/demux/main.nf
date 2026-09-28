// DEMUX — exact inline-barcode demultiplexing of ONE library with cutadapt (PLAN §3 row 1, §0 Task 2).
//
// One task per library; maxForks 1 in conf/modules.config (one library in flight, PLAN §5 rule 3). The raw library is
// read in place (read-only, staged as symlinks); lanes are streamed in the given order through a named pipe, so nothing is
// copied. Batch-1 plate pools are tar members (meta.tar_members_r1 / _r2), streamed with `tar -xOf`.
//
// Read structure per source (fgbio notation, params.read_structure_*; Twist FlexPrep 6B2S+T on both reads for BC1 and
// BC2S3 batch 2, Twist 96-Plex 8B12S+T / 8S+T for batch 1): the barcode (B) and the skipped bases (S) that follow it are
// removed by one anchored 5' pattern ^<barcode>N{S} (N matches any base and is not an error, so -e 0 stays exact); a read
// with S but no B is cut with -u/-U. Symmetric layouts pair the R1/R2 patterns (--pair-adapters).
// Deviation from zealbc1: its `^<barcode>` left the 2 skip bases in every read (documented in the Phase B handover).
//
// --subsample N (Gate 1): the first N read pairs of the library (head on the decompressed streams), written to the task dir.
// Threads come from bin/slurm_resources.sh (hash hygiene, PLAN §2 rule 4); flags (-e 0 --no-indels ...) from ext.args.
// Reads without a barcode match are discarded (ext.args --discard-untrimmed); their count is in the JSON report.
process DEMUX {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(r1, stageAs: 'raw_r1/*'), path(r2, stageAs: 'raw_r2/*'), val(barcodes)
    val subsample

    output:
    tuple val(meta), path("demux/*_R{1,2}.fastq.gz"), emit: reads
    tuple val(meta), path("${meta.id}.cutadapt.json"), emit: json
    tuple val(meta), path("${meta.id}.cutadapt.log") , emit: log
    path "versions.yml"                               , emit: versions, topic: versions
    tuple val(meta), path("versions.yml")             , emit: versions_meta

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args ?: ''
    def prefix   = "${meta.id}"
    def rs1      = zgReadStructure(meta.read_structure_r1)
    def rs2      = zgReadStructure(meta.read_structure_r2)
    if (rs1.barcode == 0) {
        error("DEMUX ${prefix}: read structure R1 '${meta.read_structure_r1}' has no barcode (B) segment")
    }
    barcodes.each { entry ->
        def (sample, bc_r1, bc_r2) = entry
        if (bc_r1.size() != rs1.barcode || (rs2.barcode && bc_r2?.size() != rs2.barcode)) {
            error("DEMUX ${prefix}: barcode length of ${sample} (${bc_r1}/${bc_r2}) does not match read structures ${meta.read_structure_r1} ${meta.read_structure_r2}")
        }
    }
    def fa_r1    = barcodes.collect { s, b1, _b2 -> "${s} ${b1}${'N' * rs1.skip}" }.join(' ')
    def fa_r2    = rs2.barcode ? barcodes.collect { s, _b1, b2 -> "${s} ${b2}${'N' * rs2.skip}" }.join(' ') : ''
    def patterns = "-g ^file:barcodes_r1.fa" + (rs2.barcode ? " -G ^file:barcodes_r2.fa --pair-adapters" : '')
    def cuts     = rs2.barcode == 0 && rs2.skip > 0 ? "-U ${rs2.skip}" : ''
    def r1_files = [r1].flatten()
    def r2_files = [r2].flatten()
    def read_r1  = meta.tar_members_r1 ? meta.tar_members_r1.collect { m -> "tar -xOf ${r1_files[0]} '${m}'" }.join('; ') : "cat ${r1_files.join(' ')}"
    def read_r2  = meta.tar_members_r2 ? meta.tar_members_r2.collect { m -> "tar -xOf ${r2_files[0]} '${m}'" }.join('; ') : "cat ${r2_files.join(' ')}"
    def samples  = barcodes.collect { entry -> entry[0] }.join(' ')
    """
    source "${projectDir}/bin/slurm_resources.sh"

    printf '>%s\\n%s\\n' ${fa_r1} > barcodes_r1.fa
    if [ -n "${fa_r2}" ]; then
        printf '>%s\\n%s\\n' ${fa_r2} > barcodes_r2.fa
    fi

    read_r1() {
        ${read_r1}
    }
    read_r2() {
        ${read_r2}
    }

    writers=""
    trap '[ -z "\$writers" ] || kill \$writers 2>/dev/null || true' EXIT
    if [ "${subsample}" -gt 0 ]; then
        n_lines=\$(( ${subsample} * 4 ))
        ( set +o pipefail; read_r1 | pigz -dc | head -n "\$n_lines" ) > in_R1.fastq
        ( set +o pipefail; read_r2 | pigz -dc | head -n "\$n_lines" ) > in_R2.fastq
        in1=in_R1.fastq
        in2=in_R2.fastq
    else
        mkfifo in_R1.fastq.gz in_R2.fastq.gz
        read_r1 > in_R1.fastq.gz &
        w1=\$!
        read_r2 > in_R2.fastq.gz &
        w2=\$!
        writers="\$w1 \$w2"
        in1=in_R1.fastq.gz
        in2=in_R2.fastq.gz
    fi

    mkdir demux
    cutadapt \\
        -j "\$ZG_CPUS" \\
        ${args} \\
        ${patterns} \\
        ${cuts} \\
        --json ${prefix}.cutadapt.json \\
        -o 'demux/{name}_R1.fastq.gz' \\
        -p 'demux/{name}_R2.fastq.gz' \\
        "\$in1" "\$in2" \\
        > ${prefix}.cutadapt.log

    if [ -n "\$writers" ]; then
        wait \$w1
        wait \$w2
        writers=""
    fi
    rm -f in_R1.fastq in_R2.fastq in_R1.fastq.gz in_R2.fastq.gz

    for s in ${samples}; do
        for r in R1 R2; do
            [ -e "demux/\${s}_\${r}.fastq.gz" ] || printf '' | pigz > "demux/\${s}_\${r}.fastq.gz"
        done
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        cutadapt: \$(cutadapt --version)
        pigz: \$(pigz --version 2>&1 | sed 's/pigz //')
    END_VERSIONS
    """

    stub:
    def prefix = "${meta.id}"
    def touch_reads = barcodes.collect { entry -> "echo '' | gzip > demux/${entry[0]}_R1.fastq.gz; echo '' | gzip > demux/${entry[0]}_R2.fastq.gz" }.join('; ')
    """
    mkdir demux
    ${touch_reads}
    echo '{"cutadapt_version": "stub", "read_counts": {"input": 0, "output": 0}, "adapters_read1": [], "adapters_read2": null}' > ${prefix}.cutadapt.json
    touch ${prefix}.cutadapt.log

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        cutadapt: stub
        pigz: stub
    END_VERSIONS
    """
}

// fgbio-style read structure of one read, as used here: [<n>B][<m>S]+T  ->  [barcode: n, skip: m]
def zgReadStructure(String rs) {
    def m = (rs ?: '') =~ /^(?:(\d+)B)?(?:(\d+)S)?\+T$/
    if (!m.matches()) {
        error("unsupported read structure '${rs}' (expected [<n>B][<m>S]+T, e.g. 6B2S+T, 8B12S+T, 8S+T)")
    }
    return [barcode: (m.group(1) ?: '0') as int, skip: (m.group(2) ?: '0') as int]
}
