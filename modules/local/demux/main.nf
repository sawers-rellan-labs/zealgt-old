// DEMUX — exact inline-barcode demultiplexing of ONE lane of one library with cutadapt (PLAN §3 row 1, §0 Task 2).
//
// One task per library x lane (READ_DEMULTIPLEXING splits the library; MERGE_LANES then joins each sample's lane files, and
// DEMUX_QC sums the lane reports), so every read of the library is demultiplexed exactly once and the lanes run in
// parallel. No maxForks: the run guards bound the libraries of a run by --max_libraries (PLAN §5 rule 3).
// cutadapt reads the delivered lane FASTQs in place (read-only, staged as symlinks): one real file per read, nothing is
// streamed or copied. Gate 2 (job 972171): a gzip stream through a named pipe fails with cutadapt 4.9 / xopen 2.1.0 at -j > 1
// ("File or stream is not seekable."; xopen sniffs the format by seeking). Batch-1 plate pools are tar members (input
// tar_members = [R1 member, R2 member] of this lane): each member is extracted to the task dir (`tar -xOf`, a real file),
// since cutadapt cannot read a tar. No `--occurrence=1` (GNU-only; bsdtar on the laptop fixtures lacks it): tar seeks past
// the remaining headers, 0.07 s for the last member of a 753 GB plate tar (batch-1 audit G9).
// Task-dir copies (tar members, --subsample heads) are removed by an EXIT trap, so a failed cutadapt does not leave ~2 x 24 GB
// in a failed task dir either; the staged raw files (raw_r1/, raw_r2/) are never touched.
//
// Read structure per source (input read_structures = [R1, R2], fgbio notation, params.read_structure_*; Twist FlexPrep
// 6B2S+T on both reads for BC1 and BC2S3 batch 2, Twist 96-Plex 8B12S+T / 8S+T for batch 1): the barcode (B) and the skipped
// bases (S) that follow it are removed by one anchored 5' pattern ^<barcode>N{S} (N matches any base and is not an error, so
// -e 0 stays exact); a read with S but no B is cut with -u/-U. Symmetric layouts pair the R1/R2 patterns (--pair-adapters).
// Deviation from zealbc1: its `^<barcode>` left the 2 skip bases in every read (documented in the Phase B handover).
//
// --subsample N (Gate 1): N is read pairs per LIBRARY; each of the library's n_lanes lanes (input n_lanes) contributes its first
// ceil(N / n_lanes) pairs (head on the decompressed lane, re-compressed with pigz -1 into the task dir), so the library total
// is N rounded up to a multiple of the lane count. cutadapt therefore always reads a real .fastq.gz file, as in the full run
// (PLAN §6: Gate 1 takes the full run's I/O path; batch-1 audit G2), for plain-FASTQ and tar libraries alike.
// Threads: cutadapt -j / pigz -p task.cpus (standard nf-core; not hashed on Nextflow >= 26.04.6); flags (-e 0 --no-indels ...)
// from ext.args.
// Reads without a barcode match are discarded (ext.args --discard-untrimmed); their count is in the JSON report.
// meta.id = <library>.<lane> (READ_DEMULTIPLEXING). Output names: demux/<sample>.<meta.id>_R{1,2}.fastq.gz (the lane keeps the files of one sample apart in MERGE_LANES).
// Tool versions: one `versions` topic tuple per tool (cutadapt, pigz, tar); coreutils (head) is pinned in environment.yml
// and not reported.
process DEMUX {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(r1, stageAs: 'raw_r1/*'), path(r2, stageAs: 'raw_r2/*'), val(barcodes), val(read_structures), val(tar_members), val(n_lanes)
    val subsample

    output:
    tuple val(meta), path("demux/*_R{1,2}.fastq.gz")                                  , emit: reads
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cutadapt.json")         , emit: json
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.cutadapt.log")          , emit: log
    tuple val("${task.process}"), val('cutadapt'), eval('cutadapt --version')                        , emit: versions_cutadapt, topic: versions
    tuple val("${task.process}"), val('pigz')    , eval("pigz --version 2>&1 | sed 's/pigz //'")     , emit: versions_pigz, topic: versions
    tuple val("${task.process}"), val('tar')     , eval('tar --version | head -1 | grep -oE "[0-9]+([.][0-9]+)+" | head -1'), emit: versions_tar, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args ?: ''
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def lane     = prefix
    def (rs_r1, rs_r2) = read_structures
    def (member_r1, member_r2) = tar_members
    def rs1      = zgReadStructure(rs_r1)
    def rs2      = zgReadStructure(rs_r2)
    if (rs1.barcode == 0) {
        error("DEMUX ${prefix}: read structure R1 '${rs_r1}' has no barcode (B) segment")
    }
    if (!(lane ==~ /[A-Za-z0-9._-]+/) || !((n_lanes as String) ==~ /[1-9][0-9]*/)) {
        error("DEMUX ${prefix}: prefix must be [A-Za-z0-9._-]+ and n_lanes a positive integer (got '${n_lanes}')")
    }
    barcodes.each { entry ->
        def (sample, bc_r1, bc_r2) = entry
        if (bc_r1.size() != rs1.barcode || (rs2.barcode && bc_r2?.size() != rs2.barcode)) {
            error("DEMUX ${prefix}: barcode length of ${sample} (${bc_r1}/${bc_r2}) does not match read structures ${rs_r1} ${rs_r2}")
        }
    }
    def fa_r1    = barcodes.collect { s, b1, _b2 -> "${s} ${b1}${'N' * rs1.skip}" }.join(' ')
    def fa_r2    = rs2.barcode ? barcodes.collect { s, _b1, b2 -> "${s} ${b2}${'N' * rs2.skip}" }.join(' ') : ''
    def patterns = "-g ^file:barcodes_r1.fa" + (rs2.barcode ? " -G ^file:barcodes_r2.fa --pair-adapters" : '')
    def cuts     = rs2.barcode == 0 && rs2.skip > 0 ? "-U ${rs2.skip}" : ''
    def lane_pairs = (subsample as long) > 0 ? ((subsample as long) + (n_lanes as long) - 1).intdiv(n_lanes as long) : 0
    def read_r1  = member_r1 ? "tar -xOf ${r1} '${member_r1}'" : "cat ${r1}"
    def read_r2  = member_r2 ? "tar -xOf ${r2} '${member_r2}'" : "cat ${r2}"
    def samples  = barcodes.collect { entry -> entry[0] }.join(' ')
    """
    printf '>%s\\n%s\\n' ${fa_r1} > barcodes_r1.fa
    if [ -n "${fa_r2}" ]; then
        printf '>%s\\n%s\\n' ${fa_r2} > barcodes_r2.fa
    fi

    trap 'rm -f ${lane}_R1.fastq.gz ${lane}_R2.fastq.gz' EXIT
    if [ "${lane_pairs}" -gt 0 ]; then
        n_lines=\$(( ${lane_pairs} * 4 ))
        ( set +o pipefail; ${read_r1} | pigz -dc | head -n "\$n_lines" | pigz -1 -p ${task.cpus} ) > ${lane}_R1.fastq.gz
        ( set +o pipefail; ${read_r2} | pigz -dc | head -n "\$n_lines" | pigz -1 -p ${task.cpus} ) > ${lane}_R2.fastq.gz
        in1=${lane}_R1.fastq.gz
        in2=${lane}_R2.fastq.gz
    elif [ -n "${member_r1}" ]; then
        ${read_r1} > ${lane}_R1.fastq.gz
        ${read_r2} > ${lane}_R2.fastq.gz
        in1=${lane}_R1.fastq.gz
        in2=${lane}_R2.fastq.gz
    else
        in1=${r1}
        in2=${r2}
    fi

    mkdir demux
    cutadapt \\
        -j ${task.cpus} \\
        ${args} \\
        ${patterns} \\
        ${cuts} \\
        --json ${prefix}.cutadapt.json \\
        -o 'demux/{name}.${lane}_R1.fastq.gz' \\
        -p 'demux/{name}.${lane}_R2.fastq.gz' \\
        "\$in1" "\$in2" \\
        > ${prefix}.cutadapt.log

    for s in ${samples}; do
        for r in R1 R2; do
            [ -e "demux/\${s}.${lane}_\${r}.fastq.gz" ] || printf '' | pigz > "demux/\${s}.${lane}_\${r}.fastq.gz"
        done
    done
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def touch_reads = barcodes.collect { entry -> "echo '' | gzip > demux/${entry[0]}.${prefix}_R1.fastq.gz; echo '' | gzip > demux/${entry[0]}.${prefix}_R2.fastq.gz" }.join('; ')
    """
    mkdir demux
    ${touch_reads}
    echo '{"cutadapt_version": "4.9", "read_counts": {"input": 0, "output": 0}, "adapters_read1": [], "adapters_read2": null}' > ${prefix}.cutadapt.json
    touch ${prefix}.cutadapt.log
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
