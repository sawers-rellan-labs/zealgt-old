//
// READ_TRIMMING (PLAN §3 row 1b): CUTADAPT (nf-core module: the full TruSeq read-through adapter on each read, NovaSeq
// poly-G-aware 3' quality trimming and a minimum length; ext.args from params.trim_adapter_r1 / params.trim_adapter_r2 /
// params.trim_args, conf/modules.config) -> FASTQC of the trimmed pairs. Stage 1 of --entry read_demultiplexing;
// CUTADAPT's publishDir hardlinks each trimmed pair and its log into the FASTQ checkpoint <fastq_checkpoint>/<library>/
// (same filesystem as work/: no extra space or inode; conf/modules.config), which --entry read_alignment reads.
// The module reads meta.single_end: false for every pair (zgCheckpointMeta).
//
include { CUTADAPT } from '../../../modules/nf-core/cutadapt/main'
include { FASTQC   } from '../../../modules/nf-core/fastqc/main'

workflow READ_TRIMMING {

    take:
    ch_reads    // channel: [ val(meta), [ R1, R2 ] ]  demultiplexed reads (meta.single_end false)

    main:
    CUTADAPT(ch_reads)
    FASTQC(CUTADAPT.out.reads)

    emit:
    reads    = CUTADAPT.out.reads // channel: [ val(meta), [ <prefix>_1.trim.fastq.gz, <prefix>_2.trim.fastq.gz ] ]
    qc       = CUTADAPT.out.log.mix(FASTQC.out.zip) // channel: [ val(meta), QC file ]  (MultiQC)
    versions = CUTADAPT.out.versions_cutadapt.mix(FASTQC.out.versions_fastqc) // channel: [ process, tool, version ]
    task_outputs = CUTADAPT.out.reads.map { meta, reads -> [meta.library, 'CUTADAPT', [reads].flatten()[0]] }
        .mix(FASTQC.out.zip.map { meta, zips -> [meta.library, 'FASTQC', [zips].flatten()[0]] }) // channel: [ library, process, one output file of the task ]  (cleanup report: the task's work dir)
}
