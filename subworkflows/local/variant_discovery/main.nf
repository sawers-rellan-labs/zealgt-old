//
// VARIANT_DISCOVERY (stage 3; PLAN §3 row 3; genotype design §2.2; zealbc1 PHG/bin/donor_discovery_chr10.sbatch), per unit
// (donor x region):
//   REGION_BED (per region) -> MASK_READ_STARTS (per role group: the donor's BC1 samples, its lines; the B73 controls per region)
//   lines -> WITNESS_POOL -> CRISP (BC1 pools + witness) -> BED_CLIP (bcftools view -T region BED) -> WITNESS_VETO
//   -> B73_CONTROL_COUNTS (B73 controls at the kept sites) [+ BC1_SITE_COUNTS when tier_counts_source = mpileup]
//   -> POOLED_LIKELIHOOD_TIERS (stored in <outdir>/genotype/<key>/step4: <donor>.<label>.sites.tsv.gz, summary, pool_qc, run_info)
// Sample map of step 4 (zealbc1 map.tsv): BC1 pools -> donor, witness <donor without dots>_BC2S3 -> donor BC2S3 (crisp mode
// only: a counts table has no witness column), B73 controls -> donor B73. No B73 group for a region (stub runs only; the utils
// guard refuses it in a real run) -> no extra counts.
//
include { REGION_BED                          } from '../../../modules/local/region_bed/main'
include { MASK_READ_STARTS                    } from '../../../modules/local/mask_read_starts/main'
include { WITNESS_POOL                        } from '../../../modules/local/witness_pool/main'
include { CRISP                               } from '../../../modules/local/crisp/main'
include { BCFTOOLS_VIEW as BED_CLIP           } from '../../../modules/nf-core/bcftools/view/main'
include { WITNESS_VETO                        } from '../../../modules/local/witness_veto/main'
include { ALLELE_COUNTS as B73_CONTROL_COUNTS } from '../../../modules/local/allele_counts/main'
include { ALLELE_COUNTS as BC1_SITE_COUNTS    } from '../../../modules/local/allele_counts/main'
include { POOLED_LIKELIHOOD_TIERS             } from '../../../modules/local/pooled_likelihood_tiers/main'

def zgBamIds(bams) {
    return [bams].flatten().collect { b -> b.name - ~/\.bam$/ }
}

// unit meta (donor x region) of a role group
def zgUnit(Map g) {
    return [id: g.unit, donor: g.donor, region: g.region, interval: g.interval]
}

// witness pool name: CRISP --sm 0 names a pool by its file name up to the first dot (design §2.2, zealbc1 :24)
def zgWitness(String donor) {
    return "${donor.replace('.', '')}_BC2S3".toString()
}

workflow VARIANT_DISCOVERY {

    take:
    ch_groups          // channel: [ val(gmeta), [ crams ], [ crais ], val([ ids ]), val([ masks ]) ]  roles bc1_sample, line, b73_control
    ch_regions         // channel: [ val(rmeta), val(region) ]
    ch_lowcopy         // channel: value [ val(meta), bed ]
    ch_ref             // channel: value [ val(meta), fasta, fai ]
    ch_annotations     // channel: value [ val([ names ]), [ site lists ] ]  or [ [], [] ]
    tier_counts_source // string: crisp | mpileup (params.tier_counts_source)

    main:
    def ch_rb = ch_regions.combine(ch_lowcopy).multiMap { rmeta, region, _lmeta, bed ->
        bed: [rmeta, bed]
        region: region
    }
    REGION_BED(ch_rb.bed, ch_rb.region)
    def ch_beds = REGION_BED.out.bed.map { rmeta, bed -> [rmeta.id, rmeta, bed] }

    def ch_mask = ch_groups
        .map { g, crams, crais, ids, masks -> [g.region, g, crams, crais, ids, masks] }
        .combine(ch_beds, by: 0)
        .multiMap { _l, g, crams, crais, ids, masks, rmeta, bed ->
            reads: [g, crams, crais, ids, masks]
            bed: [rmeta, bed]
            region: g.interval
        }
    MASK_READ_STARTS(ch_mask.reads, ch_mask.bed, ch_ref, ch_mask.region)
    def ch_masked = MASK_READ_STARTS.out.bam
        .map { g, bams, bais -> [g, [bams].flatten(), [bais].flatten()] }
        .branch { g, _bams, _bais ->
            bc1: g.role == 'bc1_sample'
            lines: g.role == 'line'
            b73: true
        }

    WITNESS_POOL(ch_masked.lines.map { g, bams, bais -> [zgUnit(g), bams, bais, zgWitness(g.donor)] }, ch_ref)

    def ch_bc1 = ch_masked.bc1.map { g, bams, bais -> [g.unit, g, bams, bais] }
    def ch_crisp = ch_bc1
        .join(WITNESS_POOL.out.bam.map { u, bam, bai -> [u.id, bam, bai] }, failOnMismatch: true)
        .map { _id, g, bams, bais, wbam, wbai -> [g.region, zgUnit(g), bams, bais, wbam, wbai] }
        .combine(ch_beds, by: 0)
        .multiMap { _l, u, bams, bais, wbam, wbai, rmeta, bed ->
            reads: [u, bams, bais, wbam, wbai]
            bed: [rmeta, bed]
            region: u.interval
        }
    CRISP(ch_crisp.reads, ch_crisp.bed, ch_ref, ch_crisp.region)

    def ch_clip = CRISP.out.vcf
        .map { u, vcf, tbi -> [u.region, u, vcf, tbi] }
        .combine(ch_beds, by: 0)
        .multiMap { _l, u, vcf, tbi, _rmeta, bed ->
            vcf: [u, vcf, tbi]
            targets: bed
        }
    BED_CLIP(ch_clip.vcf, [], ch_clip.targets, [])

    def ch_veto = BED_CLIP.out.vcf.multiMap { u, vcf ->
        vcf: [u, vcf]
        witness: zgWitness(u.donor)
    }
    WITNESS_VETO(ch_veto.vcf, ch_veto.witness)

    // B73 controls counted at each unit's kept sites
    def ch_b73c = WITNESS_VETO.out.sites
        .map { u, sites -> [u.region, u, sites] }
        .combine(ch_masked.b73.map { g, bams, bais -> [g.region, bams, bais] }, by: 0)
        .multiMap { _l, u, sites, bams, bais ->
            bams: [u, bams, bais, zgBamIds(bams)]
            sites: [u, sites]
            region: u.interval
        }
    B73_CONTROL_COUNTS(ch_b73c.bams, ch_b73c.sites, ch_ref, ch_b73c.region)

    // step-4 input: the vetoed CRISP VCF (crisp) or the BC1 counts at the kept sites (mpileup, design §4 #6)
    def ch_calls = WITNESS_VETO.out.vcf.map { u, vcf -> [u.id, vcf, []] }
    if (tier_counts_source == 'mpileup') {
        def ch_bc1c = WITNESS_VETO.out.sites
            .map { u, sites -> [u.id, u, sites] }
            .join(ch_bc1, failOnMismatch: true)
            .multiMap { _id, u, sites, _g, bams, bais ->
                bams: [u, bams, bais, zgBamIds(bams)]
                sites: [u, sites]
                region: u.interval
            }
        BC1_SITE_COUNTS(ch_bc1c.bams, ch_bc1c.sites, ch_ref, ch_bc1c.region)
        ch_calls = BC1_SITE_COUNTS.out.counts
            .map { u, counts -> [u.id, counts] }
            .join(WITNESS_VETO.out.sites.map { u, sites -> [u.id, sites] }, failOnMismatch: true)
    }
    def ch_b73_ids = ch_masked.b73
        .map { g, bams, _bais -> [g.region, zgBamIds(bams)] }
        .toList()
        .map { l -> [l.collectEntries()] }
    def ch_tiers = ch_bc1
        .join(ch_calls, failOnMismatch: true)
        .join(B73_CONTROL_COUNTS.out.counts.map { u, counts -> [u.id, counts] }, remainder: true)
        .combine(ch_b73_ids)
        .multiMap { _id, g, bams, _bais, calls, sites, b73, b73_ids ->
            input: [zgUnit(g), calls, b73 ?: [], sites]
            sample_map: zgBamIds(bams).collect { s -> [s, g.donor, g.taxon, 'bc1_sample'] } +
                        (tier_counts_source == 'mpileup' ? [] : [[zgWitness(g.donor), 'BC2S3', g.taxon, 'witness']]) +
                        (b73_ids[g.region] ?: []).collect { s -> [s, 'B73', 'B73', 'b73_control'] }
            region: g.interval
        }
    POOLED_LIKELIHOOD_TIERS(ch_tiers.input, ch_tiers.sample_map, ch_tiers.region, ch_annotations)

    emit:
    sites    = POOLED_LIKELIHOOD_TIERS.out.sites   // channel: [ val(unit), <donor>.<label>.sites.tsv.gz ]  (step4 store)
    summary  = POOLED_LIKELIHOOD_TIERS.out.summary // channel: [ val(unit), <unit>.summary.tsv ]
    vcf      = WITNESS_VETO.out.vcf                // channel: [ val(unit), <unit>.vetoed.vcf.gz ]
    b73      = B73_CONTROL_COUNTS.out.counts       // channel: [ val(unit), <unit>.b73.ad.tsv.gz ]
    // versions.yml files; BED_CLIP (nf-core) reports bcftools as an `eval` tuple into the `versions` topic only (collated by
    // workflows/genotype.nf), so this channel holds one item type
    versions = REGION_BED.out.versions.mix(WITNESS_VETO.out.versions,
                                           POOLED_LIKELIHOOD_TIERS.out.versions) // channel: versions.yml (the eval tuples of the bash modules: topic `versions` only)
}
