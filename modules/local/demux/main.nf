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
// head closes the pipe early, so the stages before it (tar / cat, pigz -dc) may die of SIGPIPE (exit 141): pipefail is off
// around that pipe and zg_pipe_ok checks PIPESTATUS instead: the producer stages must exit 0 or 141, head and the compressor
// 0. A corrupt or missing tar member / gzip therefore fails the task instead of giving a short or empty lane.
// Threads: cutadapt -j / pigz -p task.cpus (standard nf-core; not hashed on Nextflow >= 26.04.6); flags (-e 0 --no-indels ...)
// from ext.args.
// Output compression (CRAM Gate 2 w01, BZea5 OOM + 2 h hang, agent/20260929_194500_demux_batch1_oom_hang.md): cutadapt
// writes PLAIN FASTQ into one named pipe per output (demux/<sample>.<lane>_R{1,2}.fastq, made by mkfifo for every sample),
// each drained by its own single-threaded `pigz -1 -p 1` into the .fastq.gz. With .gz outputs cutadapt 4.9 at -j > 1 opens
// every output through xopen 2.1 / python-isal as an in-process threaded writer (one thread + ~3-4 MB of buffers per
// output): 192 outputs (96 batch-1 barcodes) hold ~0.8-1.1 GB in the main process, and on hazel the job was OOM-killed at
// 2 GB and again at 4 GB. Plain outputs keep the main process at ~40 MB whatever the input size; the compressors ~1.5 MB
// each; no transient uncompressed file touches the disk. Every sample gets a FIFO, so a sample without reads still gets a
// valid empty .fastq.gz.
// cutadapt runs in its own process group (set -m around the background job): when its main process dies (the cgroup OOM
// killer picks it), its forked reader/worker processes are orphaned, deadlock at 0 CPU and keep the stderr pipe of the
// Nextflow wrapper (`| tee .command.err`) open, so the task sat until the Slurm time limit (exit 140) instead of failing
// with 137. On a non-zero exit of cutadapt its exit status is propagated (137 -> memory retry); on any exit path the EXIT
// trap kills what still runs (cutadapt's group, the compressors) and removes the FIFOs and the task-dir copies.
// Measured on hazel (2026-10-01, docs/REQUIREMENTS.md §4): a full batch-1 lane (224 M pairs, 96 barcodes) ran in 53 min 35 at
// 4 cpus, flat at 529-533 MB anon; failure paths (cutadapt killed with orphaned workers, a failing command after the
// compressors started) end the task in 1-2 s (production image, Docker).
// Reads without a barcode match are discarded (ext.args --discard-untrimmed); their count is in the JSON report.
// meta.id = <library>.<lane> (READ_DEMULTIPLEXING). Output names: demux/<sample>.<meta.id>_R{1,2}.fastq.gz (the lane keeps the files of one sample apart in MERGE_LANES).
// Tool versions: one `versions` topic tuple per tool (cutadapt, pigz, tar); coreutils (head) is pinned in environment.yml
// and not reported.
process DEMUX {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/49/498407a88cdd8b16f9d68461500dcfc261f1ac3f4fff33bd208e54654dda0b8c/data'
        : 'community.wave.seqera.io/library/cutadapt_python_pigz_coreutils_pruned:06082470000c3a86'}"

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

    # EXIT trap: on any exit path, stop what is still running (cutadapt's process group, the compressors: a pigz left blocked
    # on its FIFO would keep the task's stderr pipe open, the w01 hang) and remove the task-dir copies and the FIFOs. The
    # success path clears cutadapt_pid / zips once they have ended, so nothing is signalled then.
    cutadapt_pid=''
    zips=''
    zg_cleanup() {
        if [ -n "\$cutadapt_pid" ]; then kill -KILL -- -"\$cutadapt_pid" 2>/dev/null || true; fi
        if [ -n "\$zips" ]; then kill \$zips 2>/dev/null || true; fi
        rm -f ${lane}_R1.fastq.gz ${lane}_R2.fastq.gz demux/*.${lane}_R1.fastq demux/*.${lane}_R2.fastq
    }
    trap zg_cleanup EXIT
    zg_pipe_ok() {
        local read=\$1 n i s
        shift
        n=\$#
        i=0
        for s in "\$@"; do
            i=\$(( i + 1 ))
            if [ "\$i" -le \$(( n - 2 )) ] && [ "\$s" -eq 141 ]; then
                continue
            fi
            if [ "\$s" -ne 0 ]; then
                echo "DEMUX ${prefix}: --subsample input of \$read failed: stage \$i of \$n exited \$s (PIPESTATUS \$*)" >&2
                return 1
            fi
        done
    }
    if [ "${lane_pairs}" -gt 0 ]; then
        n_lines=\$(( ${lane_pairs} * 4 ))
        ( set +o pipefail
          ${read_r1} | pigz -dc | head -n "\$n_lines" | pigz -1 -p ${task.cpus} > ${lane}_R1.fastq.gz
          zg_pipe_ok R1 "\${PIPESTATUS[@]}" ) || exit 1
        ( set +o pipefail
          ${read_r2} | pigz -dc | head -n "\$n_lines" | pigz -1 -p ${task.cpus} > ${lane}_R2.fastq.gz
          zg_pipe_ok R2 "\${PIPESTATUS[@]}" ) || exit 1
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
    for s in ${samples}; do
        for r in R1 R2; do
            mkfifo "demux/\${s}.${lane}_\${r}.fastq"
            pigz -1 -p 1 < "demux/\${s}.${lane}_\${r}.fastq" > "demux/\${s}.${lane}_\${r}.fastq.gz" &
            zips="\$zips \$!"
        done
    done
    set -m
    cutadapt \\
        -j ${task.cpus} \\
        ${args} \\
        ${patterns} \\
        ${cuts} \\
        --json ${prefix}.cutadapt.json \\
        -o 'demux/{name}.${lane}_R1.fastq' \\
        -p 'demux/{name}.${lane}_R2.fastq' \\
        "\$in1" "\$in2" \\
        > ${prefix}.cutadapt.log &
    cutadapt_pid=\$!
    set +m
    cutadapt_status=0
    wait \$cutadapt_pid || cutadapt_status=\$?
    if [ "\$cutadapt_status" -ne 0 ]; then
        echo "DEMUX ${prefix}: cutadapt exited \$cutadapt_status" >&2
        exit "\$cutadapt_status"
    fi
    cutadapt_pid=''
    for p in \$zips; do
        wait "\$p"
    done
    zips=''
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
