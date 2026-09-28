//
// DONOR_ALLELE_CALLING (stage 6; PLAN §3 row 6, "Stage 6 — two-step gap filling"; genotype design §2.5):
//   per donor x region  MASK(bc1)   -> UNION_SITE_COUNTS  --+
//   per set x region    MASK(b73)   -> B73_UNION_COUNTS   --+-> JOINT_POOLED_LIKELIHOOD (set; storeDir joint_step4/<set>)
//                                                                -> GAP_FILLING_BC1 (set, step 1; storeDir gap_bc1)
//   per donor x region  MASK(lines) -> LINE_UNION_COUNTS -> GAP_FILLING_LINES (step 2; + RTIGER segments, line_qc, the
//                                                           taxon's mappability prior; storeDir gap_lines/<set>)
//                                                        -> DONOR_FOUNDER (storeDir donor_alleles/<set>: <donor>.<label>.tsv.gz)
// Counts are batched per donor x region x role or per set x region (review #8). The union and its site list
// (MARKER_UNION) and the stage-4 segments / line_qc come from the store.
//
include { REGION_BED                                      } from '../../../modules/local/region_bed/main'
include { MASK_READ_STARTS                                } from '../../../modules/local/mask_read_starts/main'
include { ALLELE_COUNTS as UNION_SITE_COUNTS              } from '../../../modules/local/allele_counts/main'
include { ALLELE_COUNTS as B73_UNION_COUNTS               } from '../../../modules/local/allele_counts/main'
include { ALLELE_COUNTS as LINE_UNION_COUNTS              } from '../../../modules/local/allele_counts/main'
include { POOLED_LIKELIHOOD_TIERS as JOINT_POOLED_LIKELIHOOD } from '../../../modules/local/pooled_likelihood_tiers/main'
include { GAP_FILLING_BC1                                 } from '../../../modules/local/gap_filling_bc1/main'
include { GAP_FILLING_LINES                               } from '../../../modules/local/gap_filling_lines/main'
include { DONOR_FOUNDER                                   } from '../../../modules/local/donor_founder/main'

def zgBamIds(bams) {
    return [bams].flatten().collect { b -> b.name - ~/\.bam$/ }
}

def zgUnit(Map g) {
    return [id: g.unit, donor: g.donor, region: g.region, interval: g.interval]
}

workflow DONOR_ALLELE_CALLING {

    take:
    ch_groups   // channel: [ val(gmeta), [ crams ], [ crais ], val([ ids ]), val([ masks ]) ]  roles bc1_sample, line, b73_control
    ch_union    // channel: [ val(setmeta), <set>.<label>.tsv.gz, <set>.<label>.union_sites.tsv ]  one per region (store)
    ch_ancestry // channel: [ val(unit), <donor>.<label>.segments.csv, <donor>.<label>.line_qc.tsv ]  (store)
    ch_priors   // channel: [ val(donor), <taxon>.prior.tsv | [] ]  ([] with mappability_prior_mode flat)
    donor_taxa  // value: [ donor: taxon ]  run donors
    donors      // list: run donors (params.donors)
    ch_regions  // channel: [ val(rmeta), val(region) ]
    ch_lowcopy  // channel: value [ val(meta), bed ]
    ch_ref      // channel: value [ val(meta), fasta, fai ]

    main:
    def n_donors = donors.size()
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
    def ch_masked = MASK_READ_STARTS.out.bam
        .map { g, bams, bais -> [g.region, g, [bams].flatten(), [bais].flatten()] }
        .branch { _l, g, _bams, _bais ->
            bc1: g.role == 'bc1_sample'
            lines: g.role == 'line'
            b73: true
        }
    def ch_sites = ch_union.map { s, _union, sites -> [s.region, s, sites] }

    // counts at the union sites: BC1 and lines per donor x region, the B73 controls per set x region
    def ch_usc = ch_masked.bc1.combine(ch_sites, by: 0).multiMap { _l, g, bams, bais, s, sites ->
        bams: [zgUnit(g), bams, bais, zgBamIds(bams)]
        sites: [s, sites]
        region: g.interval
    }
    UNION_SITE_COUNTS(ch_usc.bams, ch_usc.sites, ch_ref, ch_usc.region)
    def ch_luc = ch_masked.lines.combine(ch_sites, by: 0).multiMap { _l, g, bams, bais, s, sites ->
        bams: [zgUnit(g), bams, bais, zgBamIds(bams)]
        sites: [s, sites]
        region: g.interval
    }
    LINE_UNION_COUNTS(ch_luc.bams, ch_luc.sites, ch_ref, ch_luc.region)
    def ch_buc = ch_masked.b73.combine(ch_sites, by: 0).multiMap { _l, _g, bams, bais, s, sites ->
        bams: [s, bams, bais, zgBamIds(bams)]
        sites: [s, sites]
        region: s.interval
    }
    B73_UNION_COUNTS(ch_buc.bams, ch_buc.sites, ch_ref, ch_buc.region)

    // step 4 at the union sites, all donors of the set at once (counts mode, no veto)
    def ch_bc1_tables = UNION_SITE_COUNTS.out.counts.map { u, t -> [u.region, t] }.groupTuple(size: n_donors, remainder: true)
    def ch_bc1_map = ch_masked.bc1
        .map { l, g, bams, _bais -> [l, zgBamIds(bams).collect { s -> [s, g.donor, g.taxon, 'bc1_sample'] }] }
        .groupTuple(size: n_donors, remainder: true)
    def ch_b73_rows = ch_masked.b73.map { l, _g, bams, _bais -> [l, zgBamIds(bams).collect { s -> [s, 'B73', 'B73', 'b73_control'] }] }
    def ch_joint = ch_sites
        .join(ch_bc1_tables, failOnMismatch: true)
        .join(ch_bc1_map, failOnMismatch: true)
        .join(B73_UNION_COUNTS.out.counts.map { s, t -> [s.region, t] }, remainder: true)
        .join(ch_b73_rows, remainder: true)
        .multiMap { _l, s, sites, tables, maps, b73, b73_rows ->
            input: [s, tables.sort { t -> t.name }, b73 ?: [], sites]
            sample_map: maps.collectMany { m -> m } + (b73_rows ?: [])
            region: s.interval
        }
    JOINT_POOLED_LIKELIHOOD(ch_joint.input, ch_joint.sample_map, ch_joint.region, [[], []])

    // step 1 per set x region
    def ch_gb = ch_union
        .map { s, union, _sites -> [s.region, s, union] }
        .join(JOINT_POOLED_LIKELIHOOD.out.sites.map { s, tables -> [s.region, [tables].flatten()] }, failOnMismatch: true)
        .map { _l, s, union, tables -> [s, union, tables] }
    GAP_FILLING_BC1(ch_gb, donors, donor_taxa)
    def ch_gap_bc1 = GAP_FILLING_BC1.out.calls.map { s, calls -> [s.region, calls] }

    // step 2 per donor x region
    def ch_gl = LINE_UNION_COUNTS.out.counts
        .map { u, counts -> [u.id, u, counts] }
        .join(ch_ancestry.map { u, seg, lq -> [u.id, seg, lq] }, failOnMismatch: true)
        .map { _id, u, counts, seg, lq -> [u.donor, u, counts, seg, lq] }
        .combine(ch_priors, by: 0)
        .map { _d, u, counts, seg, lq, prior -> [u.region, u, counts, seg, lq, prior] }
        .combine(ch_gap_bc1, by: 0)
        .multiMap { _l, u, counts, seg, lq, prior, gb ->
            input: [u, gb, counts, seg, lq, prior]
            donor: u.donor
        }
    GAP_FILLING_LINES(ch_gl.input, ch_gl.donor)

    // the donor allele per donor x region
    def ch_df = GAP_FILLING_LINES.out.calls
        .map { u, calls -> [u.region, u, calls] }
        .combine(ch_gap_bc1, by: 0)
        .combine(ch_union.map { s, union, _sites -> [s.region, union] }, by: 0)
        .multiMap { _l, u, gl, gb, union ->
            input: [u, gb, gl, union]
            donor: u.donor
        }
    DONOR_FOUNDER(ch_df.input, ch_df.donor)

    emit:
    donor_alleles = DONOR_FOUNDER.out.alleles        // channel: [ val(unit), <donor>.<label>.tsv.gz ]  (donor_alleles/<set>)
    gap_bc1       = GAP_FILLING_BC1.out.calls        // channel: [ val(setmeta), <set>.<label>.tsv.gz ]
    gap_lines     = GAP_FILLING_LINES.out.calls      // channel: [ val(unit), <donor>.<label>.tsv.gz ]
    joint         = JOINT_POOLED_LIKELIHOOD.out.sites // channel: [ val(setmeta), [ <donor>.<label>.sites.tsv.gz ] ]
    versions      = REGION_BED.out.versions.mix(MASK_READ_STARTS.out.versions, UNION_SITE_COUNTS.out.versions, LINE_UNION_COUNTS.out.versions,
                                                B73_UNION_COUNTS.out.versions, JOINT_POOLED_LIKELIHOOD.out.versions, GAP_FILLING_BC1.out.versions,
                                                GAP_FILLING_LINES.out.versions, DONOR_FOUNDER.out.versions) // channel: versions.yml
}
