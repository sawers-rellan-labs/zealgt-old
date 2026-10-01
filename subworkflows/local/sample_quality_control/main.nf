//
// SAMPLE_QUALITY_CONTROL (stage 2b; PLAN §3 row 2b; genotype design §2.1): MIN_COVERAGE on the cohort's stored
// CollectWgsMetrics, then SAMPLE_QC_TABLE (stored in <outdir>/genotype/<key>/sample_qc: cohort.sample_qc.tsv), which every later
// entry reads to drop failed samples. With a blind QC panel the role groups are masked (MASK_READ_STARTS, per donor x region x
// role, on the region's lowcopy BED) and counted at the panel sites (QC_PANEL_COUNTS), and COVERAGE_QC, RELATEDNESS_QC and
// DONOR_CONTENT_QC feed the table; without a panel (design §10 item 6) the panel tables are [] and only MIN_COVERAGE decides
// (Gate 1 path). RELATEDNESS_QC / DONOR_CONTENT_QC may also be switched off by ext.when (conf/genotype_modules.config).
//
include { MIN_COVERAGE                      } from '../../../modules/local/min_coverage/main'
include { REGION_BED                        } from '../../../modules/local/region_bed/main'
include { MASK_READ_STARTS                  } from '../../../modules/local/mask_read_starts/main'
include { ALLELE_COUNTS as QC_PANEL_COUNTS  } from '../../../modules/local/allele_counts/main'
include { COVERAGE_QC                       } from '../../../modules/local/coverage_qc/main'
include { RELATEDNESS_QC                    } from '../../../modules/local/relatedness_qc/main'
include { DONOR_CONTENT_QC                  } from '../../../modules/local/donor_content_qc/main'
include { SAMPLE_QC_TABLE                   } from '../../../modules/local/sample_qc_table/main'

// MASK_READ_STARTS writes masked/<id>.bam; one file comes back as a Path, several as a list
def zgBamIds(bams) {
    return [bams].flatten().collect { b -> b.name - ~/\.bam$/ }
}

workflow SAMPLE_QUALITY_CONTROL {

    take:
    ch_samples   // channel: [ val(meta), cram, crai, metrics, val([mask_r1, mask_r2]) ]  the cohort (run donors + B73 controls)
    ch_groups    // channel: [ val(gmeta), [ crams ], [ crais ], val([ ids ]), val([ masks ]) ]  role groups (empty without a panel)
    ch_regions   // channel: [ val(rmeta), val(region) ]
    ch_lowcopy   // channel: value [ val(meta), bed ]
    ch_ref       // channel: value [ val(meta), fasta, fai ]
    panel        // path: QC panel sites (chrom pos ref alt), or [] (panel QC not run)
    min_coverage // value: MEAN_COVERAGE floor (params.min_coverage)

    main:
    def ch_cohort     = ch_samples.toSortedList { a, b -> a[0].id <=> b[0].id }
    def ch_sample_map = ch_cohort.map { rows -> rows.collect { r -> [r[0].id, r[0].role, r[0].donor] } }

    MIN_COVERAGE(ch_cohort.map { rows -> [[id: 'cohort'], rows.collect { r -> r[3] }, rows.collect { r -> r[0].id }] }, min_coverage)

    // panel counts: REGION_BED per region, MASK_READ_STARTS per role group, QC_PANEL_COUNTS per role group
    def ch_rb = ch_regions.combine(ch_lowcopy).multiMap { rmeta, region, _lmeta, bed ->
        bed: [rmeta, bed]
        region: region
    }
    REGION_BED(ch_rb.bed, ch_rb.region)
    def ch_mask = ch_groups
        .map { g, crams, crais, ids, masks -> [g.region, g, crams, crais, ids, masks] }
        .combine(REGION_BED.out.bed.map { rmeta, bed -> [rmeta.id, rmeta, bed] }, by: 0)
        .multiMap { _l, g, crams, crais, ids, masks, rmeta, bed ->
            reads: [g, crams, crais, ids, masks]
            bed: [rmeta, bed]
            region: g.interval
        }
    MASK_READ_STARTS(ch_mask.reads, ch_mask.bed, ch_ref, ch_mask.region)
    def ch_pc = MASK_READ_STARTS.out.bam.multiMap { g, bams, bais ->
        bams: [g, [bams].flatten(), [bais].flatten(), zgBamIds(bams)]
        region: g.interval
    }
    QC_PANEL_COUNTS(ch_pc.bams, channel.value([[id: 'qc_panel'], panel]), ch_ref, ch_pc.region)

    def ch_counts = QC_PANEL_COUNTS.out.counts
        .map { _g, table -> table }
        .toSortedList { a, b -> a.name <=> b.name }
        .filter { tables -> tables }
        .map { tables -> [[id: 'cohort'], tables] }
    COVERAGE_QC(ch_counts, panel, ch_sample_map)
    RELATEDNESS_QC(ch_counts, panel, ch_sample_map)
    DONOR_CONTENT_QC(ch_counts, panel, ch_sample_map)

    // the panel tables that ran (none without a panel, or when switched off) -> [] for the others
    def ch_panel_tables = COVERAGE_QC.out.tsv.map { _m, f -> ['panel_coverage', f] }
        .mix(RELATEDNESS_QC.out.tsv.map { _m, f -> ['relatedness', f] }, DONOR_CONTENT_QC.out.tsv.map { _m, f -> ['donor_content', f] })
        .toList()
        .map { kv -> [kv.collectEntries()] }
    def ch_table = MIN_COVERAGE.out.tsv
        .combine(ch_panel_tables)
        .map { meta, mc, t -> [meta, mc, t.panel_coverage ?: [], t.relatedness ?: [], t.donor_content ?: []] }
    SAMPLE_QC_TABLE(ch_table, ch_sample_map)

    emit:
    sample_qc     = SAMPLE_QC_TABLE.out.tsv  // channel: [ val(meta), cohort.sample_qc.tsv ]
    min_coverage  = MIN_COVERAGE.out.tsv     // channel: [ val(meta), cohort.min_coverage.tsv ]
    panel_counts  = QC_PANEL_COUNTS.out.counts // channel: [ val(gmeta), <gmeta.id>.ad.tsv.gz ]
    versions      = MIN_COVERAGE.out.versions.mix(REGION_BED.out.versions,
                                              COVERAGE_QC.out.versions, RELATEDNESS_QC.out.versions, DONOR_CONTENT_QC.out.versions,
                                              SAMPLE_QC_TABLE.out.versions) // channel: versions.yml (the eval tuples of the bash modules: topic `versions` only)
}
