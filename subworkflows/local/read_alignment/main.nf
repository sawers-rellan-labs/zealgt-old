//
// READ_ALIGNMENT (PLAN §3 row 2, stage 2): ALIGN_MARKDUP (minibwa -> RG -> fixmate -> sort -> markdup -d 2500 -> CRAM,
// published to <store>/cram) -> CRAM_QC_PROVENANCE (SAMTOOLS_STATS + PICARD_COLLECTWGSMETRICS + PROVENANCE, published into
// <store>/cram). Samples whose CRAM is already stored and verified arrive in ch_stored and are not aligned again (the CRAM
// workflow decides, zgIsStored); their QC and provenance are produced only if missing.
//
include { ALIGN_MARKDUP      } from '../../../modules/local/align_markdup/main'
include { CRAM_QC_PROVENANCE } from '../cram_qc_provenance/main'

workflow READ_ALIGNMENT {

    take:
    ch_reads       // channel: [ val(meta), [ R1, R2 ] ]  trimmed reads of the samples still to align
    ch_read_groups // channel: [ sample_id, read_group ]  escaped @RG line per sample
    ch_stored      // channel: [ val(meta), cram, crai, [ versions.yml ] ]  CRAMs already in <store>/cram
    ch_ref         // channel: value [ val(meta2), fasta, fai, [ minibwa index files ] ]
    ch_records     // channel: [ sample_id, record map ]  one per sample (new and stored)
    ch_stored_qc   // channel: [ sample_id, [ QC files and provenance.json already in <store>/cram ] ]  one per sample

    main:
    def ch_align_in = ch_reads
        .map { meta, reads -> [meta.id, meta, reads] }
        .join(ch_read_groups)
        .map { _id, meta, reads, read_group -> [meta, reads, read_group] }
    ALIGN_MARKDUP(ch_align_in, ch_ref)

    // versions.yml is a path-only output (kept next to the CRAM in the store, so PROVENANCE of a stored CRAM still has it);
    // it is matched to its CRAM by the file name <prefix>.align_markdup.versions.yml
    def ch_align_versions = ALIGN_MARKDUP.out.versions.map { f -> [f.name - '.align_markdup.versions.yml', f] }
    def ch_cram = ALIGN_MARKDUP.out.cram
        .map { meta, cram, crai -> [meta.id, meta, cram, crai] }
        .join(ch_align_versions, failOnMismatch: true)
        .map { _id, meta, cram, crai, versions -> [meta, cram, crai, [versions]] }
        .mix(ch_stored)

    CRAM_QC_PROVENANCE(ch_cram, ch_ref, ch_records, ch_stored_qc)

    emit:
    cram       = ch_cram.map { meta, cram, crai, _versions -> [meta, cram, crai] } // channel: [ val(meta), cram, crai ]
    qc         = CRAM_QC_PROVENANCE.out.qc.mix(ALIGN_MARKDUP.out.markdup_stats)  // channel: [ val(meta), QC file ]
    provenance = CRAM_QC_PROVENANCE.out.provenance                                // channel: [ val(meta), json ]
    versions   = CRAM_QC_PROVENANCE.out.versions                                  // channel: [ process, tool, version ] (ALIGN_MARKDUP: versions.yml in the topic)
}
