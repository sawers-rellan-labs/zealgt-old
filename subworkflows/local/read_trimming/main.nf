//
// READ_TRIMMING (PLAN §3 row 1b): TRIMMOMATIC with batch 1's parameters (ILLUMINACLIP on the staged adapter FASTA, ext.args
// from params.trim_illuminaclip / params.trim_args) -> FASTQC of the trimmed pairs. Stage 1 of --entry read_demultiplexing;
// TRIMMOMATIC's publishDir hardlinks each trimmed pair into the FASTQ checkpoint <fastq_checkpoint>/<library>/ (same
// filesystem as work/: no extra space or inode; conf/modules.config), which --entry read_alignment reads.
//
include { TRIMMOMATIC } from '../../../modules/nf-core/trimmomatic/main'
include { FASTQC      } from '../../../modules/nf-core/fastqc/main'

workflow READ_TRIMMING {

    take:
    ch_reads    // channel: [ val(meta), [ R1, R2 ] ]  demultiplexed reads
    ch_adapters // channel: value adapter FASTA (params.trim_adapters)

    main:
    TRIMMOMATIC(ch_reads, ch_adapters)
    FASTQC(TRIMMOMATIC.out.trimmed_reads)

    emit:
    reads    = TRIMMOMATIC.out.trimmed_reads // channel: [ val(meta), [ paired.trim_1, paired.trim_2 ] ]
    qc       = TRIMMOMATIC.out.out_log.mix(TRIMMOMATIC.out.summary, FASTQC.out.zip) // channel: [ val(meta), QC file ]  (MultiQC)
    versions = TRIMMOMATIC.out.versions_trimmomatic.mix(FASTQC.out.versions_fastqc) // channel: [ process, tool, version ]
    task_outputs = TRIMMOMATIC.out.trimmed_reads.map { meta, reads -> [meta.library, 'TRIMMOMATIC', [reads].flatten()[0]] }
        .mix(FASTQC.out.zip.map { meta, zips -> [meta.library, 'FASTQC', [zips].flatten()[0]] }) // channel: [ library, process, one output file of the task ]  (cleanup report: the task's work dir)
}
