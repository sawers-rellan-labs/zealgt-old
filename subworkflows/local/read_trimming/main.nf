//
// READ_TRIMMING (PLAN §3 row 1b): TRIMMOMATIC with batch 1's parameters (ext.args from params.trim_args, adapters from
// params.trim_adapters) -> FASTQC of the trimmed pairs. Trimmed FASTQs stay in work/ until the library's CRAMs are stored.
//
include { TRIMMOMATIC } from '../../../modules/nf-core/trimmomatic/main'
include { FASTQC      } from '../../../modules/nf-core/fastqc/main'

workflow READ_TRIMMING {

    take:
    ch_reads // channel: [ val(meta), [ R1, R2 ] ]

    main:
    TRIMMOMATIC(ch_reads)
    FASTQC(TRIMMOMATIC.out.trimmed_reads)

    def ch_qc = TRIMMOMATIC.out.out_log.map { meta, f -> [meta.qc_group, f] }
        .mix(TRIMMOMATIC.out.summary.map { meta, f -> [meta.qc_group, f] })
        .mix(FASTQC.out.zip.map { meta, f -> [meta.qc_group, f] })
    def ch_trim_version = TRIMMOMATIC.out.versions_trimmomatic
        .map { _process, _tool, version -> version }
        .unique()
        .collect()
        .map { versions -> versions.join(',') }

    emit:
    reads        = TRIMMOMATIC.out.trimmed_reads // channel: [ val(meta), [ paired.trim_1, paired.trim_2 ] ]
    qc           = ch_qc                         // channel: [ qc_group, file ]  (MultiQC per library)
    trim_version = ch_trim_version               // channel: value 'x.y' (for provenance)
}
