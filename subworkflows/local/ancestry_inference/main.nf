//
// ANCESTRY_INFERENCE (stage 4; PLAN §3 row 4, §4 #10 / #13; genotype design §2.3; zealbc1 rtiger_ancestry_inference.sbatch),
// per unit (donor x region):
//   step-4 table (store) -> RTIGER_MARKERS (own tier-A sites; storeDir ancestry/, also read by reporting)
//   lines -> MASK_READ_STARTS -> LINE_ALLELE_COUNTS (at the tier-A sites) -> LINE_MARKER_QC (coverage floor
//   min_markers_factor x rigidity; storeDir ancestry/: counts + line_qc) -> RTIGER (storeDir ancestry/: <donor>.<label>.segments.csv)
// Every unit needs a line group (all lines of a donor failing sample QC stops the join with an error, not silently).
//
include { REGION_BED                          } from '../../../modules/local/region_bed/main'
include { MASK_READ_STARTS                    } from '../../../modules/local/mask_read_starts/main'
include { RTIGER_MARKERS                      } from '../../../modules/local/rtiger_markers/main'
include { ALLELE_COUNTS as LINE_ALLELE_COUNTS } from '../../../modules/local/allele_counts/main'
include { LINE_MARKER_QC                      } from '../../../modules/local/line_marker_qc/main'
include { RTIGER                              } from '../../../modules/local/rtiger/main'

def zgBamIds(bams) {
    return [bams].flatten().collect { b -> b.name - ~/\.bam$/ }
}

// nilHMM needs an integer chromosome: chr10 -> 10 (design §2.3)
def zgChromInt(String region) {
    def chrom = region.tokenize(':')[0]
    def n = chrom.replaceFirst(/^(?i)chr/, '')
    return n.isInteger() ? n.toInteger() : error("ANCESTRY_INFERENCE: chromosome '${chrom}' of region ${region} has no integer number for RTIGER")
}

workflow ANCESTRY_INFERENCE {

    take:
    ch_groups          // channel: [ val(gmeta), [ crams ], [ crais ], val([ ids ]), val([ masks ]) ]  line groups (donor x region)
    ch_step4           // channel: [ val(unit), <donor>.<label>.sites.tsv.gz ]  step-4 tables from the store
    ch_regions         // channel: [ val(rmeta), val(region) ]
    ch_lowcopy         // channel: value [ val(meta), bed ]
    ch_ref             // channel: value [ val(meta), fasta, fai ]
    rigidity           // value: RTIGER rigidity (params.rigidity)
    min_markers_factor // value: covered-marker floor factor (params.min_markers_factor)

    main:
    RTIGER_MARKERS(ch_step4)

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

    def ch_markers = RTIGER_MARKERS.out.sites.map { u, sites -> [u.id, u, sites] }
    def ch_lac = MASK_READ_STARTS.out.bam
        .map { g, bams, bais -> [g.unit, [bams].flatten(), [bais].flatten()] }
        .join(ch_markers, failOnMismatch: true)
        .multiMap { _id, bams, bais, u, sites ->
            bams: [u, bams, bais, zgBamIds(bams)]
            sites: [u, sites]
            region: u.interval
        }
    LINE_ALLELE_COUNTS(ch_lac.bams, ch_lac.sites, ch_ref, ch_lac.region)

    def ch_lmq = LINE_ALLELE_COUNTS.out.counts
        .map { u, counts -> [u.id, u, counts] }
        .join(ch_markers.map { id, _u, sites -> [id, sites] }, failOnMismatch: true)
        .map { _id, u, counts, sites -> [u, counts, sites] }
    LINE_MARKER_QC(ch_lmq, rigidity, min_markers_factor)

    def ch_rt = LINE_MARKER_QC.out.counts.multiMap { u, counts ->
        counts: [u, counts]
        chrom_int: zgChromInt(u.interval)
        donor: u.donor
    }
    RTIGER(ch_rt.counts, rigidity, ch_rt.chrom_int, ch_rt.donor)

    emit:
    segments = RTIGER.out.segments          // channel: [ val(unit), <donor>.<label>.segments.csv ]
    line_qc  = LINE_MARKER_QC.out.line_qc   // channel: [ val(unit), <donor>.<label>.line_qc.tsv ]
    markers  = RTIGER_MARKERS.out.sites     // channel: [ val(unit), <donor>.<label>.tierA_sites.tsv ]
    versions = RTIGER_MARKERS.out.versions.mix(REGION_BED.out.versions, MASK_READ_STARTS.out.versions, LINE_ALLELE_COUNTS.out.versions,
                                               LINE_MARKER_QC.out.versions, RTIGER.out.versions) // channel: versions.yml
}
