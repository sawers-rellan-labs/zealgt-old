//
// GENOTYPE_IMPUTATION (stage 7; PLAN §3 row 7; genotype design §2.6; math supplement Eq. S5.1): per unit (donor x region),
// RASTERIZE = RTIGER ancestry x donor allele at every non-multiallelic union site (storeDir genotypes/<set>:
// <donor>.<label>.tsv.gz long + .matrix.tsv.gz wide). imputation_method = raster; the PHG path is a later work package
// (refused by the utils guard).
//
include { RASTERIZE } from '../../../modules/local/rasterize/main'

workflow GENOTYPE_IMPUTATION {

    take:
    ch_inputs // channel: [ val(unit), donor_alleles <donor>.<label>.tsv.gz, <donor>.<label>.segments.csv, <donor>.<label>.line_qc.tsv ]  (store)

    main:
    RASTERIZE(ch_inputs)

    emit:
    genotypes = RASTERIZE.out.genotypes // channel: [ val(unit), <donor>.<label>.tsv.gz ]
    matrix    = RASTERIZE.out.matrix    // channel: [ val(unit), <donor>.<label>.matrix.tsv.gz ]
    versions  = RASTERIZE.out.versions  // channel: versions.yml
}
