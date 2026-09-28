//
// GENOTYPE_REPORTING (stage 8, entry `reporting`; PLAN §3 row 8, §4 #12; genotype design §2.7), per unit (donor x region);
// nothing goes to the store, every output is published (conf/genotype_modules.config):
//   GENOTYPE_SUMMARY      genotype_summary.tsv, single_locus.tsv, breakpoint_density.tsv (the design's BREAKPOINT_DENSITY is
//                         folded into this module)
//   CHROMOSOME_PAINTING   <donor>.<label>.painting.png / .pdf
//   READ_POSITION_QC      (params.read_position_qc) REF / ALT / other by read cycle at the donor's own tier-A sites, per role
//                         group (BC1, lines), on the stored CRAMs (label raw) and on MASK_READ_STARTS output (label masked):
//                         the before / after view of the 5' mask. The workflow passes empty group / region channels to skip it.
//
include { GENOTYPE_SUMMARY    } from '../../../modules/local/genotype_summary/main'
include { CHROMOSOME_PAINTING } from '../../../modules/local/chromosome_painting/main'
include { REGION_BED          } from '../../../modules/local/region_bed/main'
include { MASK_READ_STARTS    } from '../../../modules/local/mask_read_starts/main'
include { READ_POSITION_QC    } from '../../../modules/local/read_position_qc/main'

def zgBamIds(bams) {
    return [bams].flatten().collect { b -> b.name - ~/\.bam$/ }
}

workflow GENOTYPE_REPORTING {

    take:
    ch_inputs  // channel: [ val(unit), genotypes <donor>.<label>.tsv.gz, segments.csv, donor_alleles tsv.gz, line_qc.tsv ]  (store)
    ch_groups  // channel: [ val(gmeta), [ crams ], [ crais ], val([ ids ]), val([ masks ]) ]  BC1 and line groups (empty: no read-position QC)
    ch_markers // channel: [ val(unit), <donor>.<label>.tierA_sites.tsv ]  (store, ancestry/)
    ch_regions // channel: [ val(rmeta), val(region) ]  (empty: no read-position QC)
    ch_lowcopy // channel: value [ val(meta), bed ]
    ch_ref     // channel: value [ val(meta), fasta, fai ]

    main:
    GENOTYPE_SUMMARY(ch_inputs)
    CHROMOSOME_PAINTING(ch_inputs.map { u, _gt, seg, _da, lq -> [u, seg, lq] })

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

    def ch_raw    = ch_groups.map { g, crams, crais, ids, _masks -> [g + [id: "${g.id}.raw".toString()], crams, crais, ids, 'raw'] }
    def ch_masked = MASK_READ_STARTS.out.bam.map { g, bams, bais -> [g + [id: "${g.id}.masked".toString()], [bams].flatten(), [bais].flatten(), zgBamIds(bams), 'masked'] }
    def ch_rpq = ch_raw.mix(ch_masked)
        .map { g, aln, idx, ids, label -> [g.unit, g, aln, idx, ids, label] }
        .combine(ch_markers.map { u, sites -> [u.id, u, sites] }, by: 0)
        .multiMap { _id, g, aln, idx, ids, label, u, sites ->
            aln: [g, aln, idx, ids]
            sites: [u, sites]
            region: g.interval
            label: label
        }
    READ_POSITION_QC(ch_rpq.aln, ch_rpq.sites, ch_ref, ch_rpq.region, ch_rpq.label)

    emit:
    summary            = GENOTYPE_SUMMARY.out.summary            // channel: [ val(unit), genotype_summary.tsv ]
    single_locus       = GENOTYPE_SUMMARY.out.single_locus       // channel: [ val(unit), single_locus.tsv ]
    breakpoint_density = GENOTYPE_SUMMARY.out.breakpoint_density // channel: [ val(unit), breakpoint_density.tsv ]
    painting           = CHROMOSOME_PAINTING.out.png             // channel: [ val(unit), painting.png ]
    read_position_qc   = READ_POSITION_QC.out.tsv                // channel: [ val(gmeta), read_position_qc.tsv ]
    versions           = GENOTYPE_SUMMARY.out.versions.mix(CHROMOSOME_PAINTING.out.versions, REGION_BED.out.versions,
                                                           MASK_READ_STARTS.out.versions, READ_POSITION_QC.out.versions) // channel: versions.yml
}
