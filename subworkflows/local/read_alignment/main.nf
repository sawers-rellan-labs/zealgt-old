//
// READ_ALIGNMENT (PLAN §3 row 2): ALIGN_MARKDUP (minibwa -> RG -> fixmate -> sort -> markdup -d 2500 -> CRAM, storeDir
// <store>/cram) -> SAMTOOLS_STATS + PICARD_COLLECTWGSMETRICS (published into <store>/cram) -> PROVENANCE (store).
// Samples whose CRAM is already stored arrive in ch_stored and skip trimming / alignment; their QC and provenance are
// produced only if missing (storeDir).
//
include { ALIGN_MARKDUP            } from '../../../modules/local/align_markdup/main'
include { SAMTOOLS_STATS           } from '../../../modules/nf-core/samtools/stats/main'
include { PICARD_COLLECTWGSMETRICS } from '../../../modules/nf-core/picard/collectwgsmetrics/main'
include { PROVENANCE               } from '../../../modules/local/provenance/main'

workflow READ_ALIGNMENT {

    take:
    ch_reads  // channel: [ val(meta), [ R1, R2 ] ]  trimmed reads of the samples still to align
    ch_stored // channel: [ val(meta), cram, crai, [ versions.yml ] ]  CRAMs already in <store>/cram
    ch_ref    // channel: value [ val(meta2), fasta, fai, [ minibwa index files ] ]
    ch_record // channel: [ sample_id, record map, [ extra versions.yml ] ]  one per sample (new and stored)
    store_dir // string: <store root>/cram, where the CRAMs and their QC live

    main:
    ALIGN_MARKDUP(ch_reads, ch_ref)

    def ch_align_versions = ALIGN_MARKDUP.out.versions.map { f -> [f.name - '.align_markdup.versions.yml', f] }
    def ch_new = ALIGN_MARKDUP.out.cram
        .map { meta, cram, crai -> [meta.id, meta, cram, crai] }
        .join(ch_align_versions, failOnMismatch: true)
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
        .mix(ALIGN_MARKDUP.out.markdup_stats.map { meta, f -> [meta.qc_group, f] })
        .mix(ch_qc_stored)

    emit:
    cram       = ch_bam           // channel: [ val(meta), cram, crai ]
    qc         = ch_qc            // channel: [ qc_group, file ]
    provenance = PROVENANCE.out.json // channel: [ val(meta), json ]
}
