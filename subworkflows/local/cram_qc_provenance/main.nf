//
// CRAM_QC_PROVENANCE: per-CRAM QC (SAMTOOLS_STATS, PICARD_COLLECTWGSMETRICS) and the PROVENANCE record, all published into the
// store next to the CRAM (conf/modules.config), shared by READ_ALIGNMENT (new CRAMs, <outdir>/cram) and CRAM_IMPORT (imported
// CRAMs, <outdir>/cram_import). QC files and provenance records already in the store arrive in ch_stored_qc and are not made
// again (the stored ones are emitted instead).
//
include { SAMTOOLS_STATS           } from '../../../modules/nf-core/samtools/stats/main'
include { PICARD_COLLECTWGSMETRICS } from '../../../modules/nf-core/picard/collectwgsmetrics/main'
include { PROVENANCE               } from '../../../modules/local/provenance/main'

workflow CRAM_QC_PROVENANCE {

    take:
    ch_cram      // channel: [ val(meta), cram, crai, [ versions.yml ] ]  every CRAM of the run (new and stored)
    ch_ref       // channel: value [ val(meta2), fasta, fai, [ index files ] ]
    ch_records   // channel: [ sample_id, record map ]  provenance settings, one per sample
    ch_stored_qc // channel: [ sample_id, [ QC files and provenance.json already in the store ] ]

    main:
    def ch_bam = ch_cram
        .map { meta, cram, crai, _versions -> [meta.id, meta, cram, crai] }
        .join(ch_stored_qc)
        .map { _id, meta, cram, crai, stored -> [meta, cram, crai, stored] }
    def ch_stats_in  = ch_bam.filter { meta, _c, _i, stored -> !stored.any { f -> f.name == "${meta.id}.stats" } }
        .map { meta, cram, crai, _stored -> [meta, cram, crai] }
    def ch_picard_in = ch_bam.filter { meta, _c, _i, stored -> !stored.any { f -> f.name == "${meta.id}.CollectWgsMetrics.coverage_metrics" } }
        .map { meta, cram, crai, _stored -> [meta, cram, crai] }

    SAMTOOLS_STATS(ch_stats_in, ch_ref.map { meta2, fasta, fai, _index -> [meta2, fasta, fai] })
    PICARD_COLLECTWGSMETRICS(
        ch_picard_in,
        ch_ref.map { meta2, fasta, _fai, _index -> [meta2, fasta] },
        ch_ref.map { meta2, _fasta, fai, _index -> [meta2, fai] },
        []
    )

    def ch_prov = ch_cram
        .map { meta, cram, _crai, versions -> [meta.id, meta, cram, versions] }
        .join(ch_records)
        .join(ch_stored_qc)
        .branch { _id, meta, _cram, _versions, _record, stored ->
            stored: stored.any { f -> f.name == "${meta.id}.provenance.json" }
            todo: true
        }
    PROVENANCE(ch_prov.todo.map { _id, meta, cram, versions, record, _stored -> [meta, cram, versions, groovy.json.JsonOutput.toJson(record)] })

    def ch_stored_files = ch_bam.flatMap { meta, _c, _i, stored -> stored.collect { f -> [meta, f] } }
    def ch_qc = SAMTOOLS_STATS.out.stats
        .mix(PICARD_COLLECTWGSMETRICS.out.metrics)
        .mix(ch_stored_files.filter { _meta, f -> !f.name.endsWith('.provenance.json') })

    emit:
    qc         = ch_qc // channel: [ val(meta), QC file ]  (new and stored; MultiQC input)
    provenance = PROVENANCE.out.json.mix(ch_stored_files.filter { _meta, f -> f.name.endsWith('.provenance.json') }) // channel: [ val(meta), <sample>.provenance.json ]  (new and stored)
    versions   = SAMTOOLS_STATS.out.versions_samtools.mix(PICARD_COLLECTWGSMETRICS.out.versions_picard) // channel: [ process, tool, version ]
}
