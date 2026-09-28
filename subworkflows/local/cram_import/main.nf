//
// CRAM_IMPORT (PLAN §0 Task 2 bullet 4): existing zealbc1 / nilhmm CRAMs -> MARKDUP_IMPORT (read groups + duplicate marking,
// no realignment; storeDir <store>/cram_import) -> SAMTOOLS_STATS + PICARD_COLLECTWGSMETRICS -> PROVENANCE, all stored
// in <store>/cram_import (conf/modules.config), apart from the CRAMs the CRAM workflow aligns itself (<store>/cram).
//
include { MARKDUP_IMPORT           } from '../../../modules/local/markdup_import/main'
include { SAMTOOLS_STATS           } from '../../../modules/nf-core/samtools/stats/main'
include { PICARD_COLLECTWGSMETRICS } from '../../../modules/nf-core/picard/collectwgsmetrics/main'
include { PROVENANCE               } from '../../../modules/local/provenance/main'

workflow CRAM_IMPORT {

    take:
    ch_input  // channel: [ val(meta), cram|bam, crai|bai ]  CRAMs to import (not yet in <store>/cram_import)
    ch_stored // channel: [ val(meta), cram, crai, [ versions.yml ] ]  imports already stored
    ch_ref    // channel: value [ val(meta2), fasta, fai, [ index files ] ]
    ch_record // channel: [ sample_id, record map, [ extra versions.yml ] ]
    store_dir // string: <store root>/cram_import, where the imported CRAMs and their QC live

    main:
    def ch_fasta_fai = ch_ref.map { meta2, fasta, fai, _index -> [meta2, fasta, fai] }
    MARKDUP_IMPORT(ch_input, ch_fasta_fai)

    def ch_import_versions = MARKDUP_IMPORT.out.versions.map { f -> [f.name - '.markdup_import.versions.yml', f] }
    def ch_new = MARKDUP_IMPORT.out.cram
        .map { meta, cram, crai -> [meta.id, meta, cram, crai] }
        .join(ch_import_versions, failOnMismatch: true)
        .map { _id, meta, cram, crai, versions -> [meta, cram, crai, [versions]] }
    def ch_cram = ch_new.mix(ch_stored)
    def ch_bam  = ch_cram.map { meta, cram, crai, _versions -> [meta, cram, crai] }

    // QC only for CRAMs whose QC file is not in the store yet (published there, see conf/modules.config)
    def ch_stats_in  = ch_bam.filter { meta, _c, _i -> !file("${store_dir}/${meta.id}.stats").exists() }
    def ch_picard_in = ch_bam.filter { meta, _c, _i -> !file("${store_dir}/${meta.id}.CollectWgsMetrics.coverage_metrics").exists() }
    def ch_qc_stored = ch_bam.flatMap { meta, _c, _i ->
        ["${meta.id}.stats", "${meta.id}.CollectWgsMetrics.coverage_metrics", "${meta.id}.markdup.stats"]
            .collect { n -> file("${store_dir}/${n}") }
            .findAll { f -> f.exists() }
            .collect { f -> [meta.qc_group, f] }
    }
    SAMTOOLS_STATS(ch_stats_in, ch_ref.map { meta2, fasta, fai, _index -> [meta2, fasta, fai] })
    PICARD_COLLECTWGSMETRICS(
        ch_picard_in,
        ch_ref.map { meta2, fasta, _fai, _index -> [meta2, fasta] },
        ch_ref.map { meta2, _fasta, fai, _index -> [meta2, fai] },
        []
    )

    def ch_prov = ch_cram
        .map { meta, cram, _crai, versions -> [meta.id, meta, cram, versions] }
        .join(ch_record)
        .map { _id, meta, cram, versions, record, extra -> [meta, cram, versions + extra, groovy.json.JsonOutput.toJson(record)] }
    PROVENANCE(ch_prov)

    def ch_qc = SAMTOOLS_STATS.out.stats.map { meta, f -> [meta.qc_group, f] }
        .mix(PICARD_COLLECTWGSMETRICS.out.metrics.map { meta, f -> [meta.qc_group, f] })
        .mix(MARKDUP_IMPORT.out.markdup_stats.map { meta, f -> [meta.qc_group, f] })
        .mix(ch_qc_stored)

    emit:
    cram       = ch_bam              // channel: [ val(meta), cram, crai ]
    qc         = ch_qc               // channel: [ qc_group, file ]
    provenance = PROVENANCE.out.json // channel: [ val(meta), json ]
}
