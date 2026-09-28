//
// CRAM_IMPORT (PLAN §0 Task 2 bullet 4): existing zealbc1 / nilhmm CRAMs -> MARKDUP_IMPORT (read groups + duplicate marking,
// no realignment; storeDir <store>/cram_import) -> CRAM_QC_PROVENANCE (SAMTOOLS_STATS + PICARD_COLLECTWGSMETRICS published
// into <store>/cram_import, PROVENANCE), apart from the CRAMs the CRAM workflow aligns itself (<store>/cram).
//
include { MARKDUP_IMPORT     } from '../../../modules/local/markdup_import/main'
include { CRAM_QC_PROVENANCE } from '../cram_qc_provenance/main'

workflow CRAM_IMPORT {

    take:
    ch_input     // channel: [ val(meta), cram|bam, crai|bai, read_group ]  CRAMs to import (not yet in <store>/cram_import)
    ch_stored    // channel: [ val(meta), cram, crai, [ versions.yml ] ]  imports already stored
    ch_ref       // channel: value [ val(meta2), fasta, fai, [ index files ] ]
    ch_records   // channel: [ sample_id, record map ]  one per sample
    ch_stored_qc // channel: [ sample_id, [ QC files already in <store>/cram_import ] ]  one per sample

    main:
    MARKDUP_IMPORT(ch_input, ch_ref.map { meta2, fasta, fai, _index -> [meta2, fasta, fai] })

    // versions.yml is a path-only output (storeDir); it is matched to its CRAM by the file name <prefix>.markdup_import.versions.yml
    def ch_import_versions = MARKDUP_IMPORT.out.versions.map { f -> [f.name - '.markdup_import.versions.yml', f] }
    def ch_cram = MARKDUP_IMPORT.out.cram
        .map { meta, cram, crai -> [meta.id, meta, cram, crai] }
        .join(ch_import_versions, failOnMismatch: true)
        .map { _id, meta, cram, crai, versions -> [meta, cram, crai, [versions]] }
        .mix(ch_stored)

    CRAM_QC_PROVENANCE(ch_cram, ch_ref, ch_records, ch_stored_qc)

    emit:
    cram       = ch_cram.map { meta, cram, crai, _versions -> [meta, cram, crai] } // channel: [ val(meta), cram, crai ]
    qc         = CRAM_QC_PROVENANCE.out.qc.mix(MARKDUP_IMPORT.out.markdup_stats) // channel: [ val(meta), QC file ]
    provenance = CRAM_QC_PROVENANCE.out.provenance                                // channel: [ val(meta), json ]
    versions   = CRAM_QC_PROVENANCE.out.versions                                  // channel: [ process, tool, version ] (MARKDUP_IMPORT: versions.yml in the topic)
}
