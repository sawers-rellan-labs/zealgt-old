//
// MARKER_UNION_STAGE (stage 5; PLAN §3 row 5; genotype design §2.4): the tier-A union of one donor set per region
// (MARKER_UNION; storeDir <store>/genotype/<key>/union: <set>.<label>.tsv.gz, .union_sites.tsv, .per_donor.tsv). The step-4
// tables of the run donors come from the store; reference donors (run card reference_donor_tables) are read-only tables of
// donors not called in the run, staged by position in the order of reference_donors. The workflow is named *_STAGE because
// its module is MARKER_UNION (a subworkflow cannot share a process's name; directory marker_union as design §8.1).
//
include { MARKER_UNION } from '../../../modules/local/marker_union/main'

workflow MARKER_UNION_STAGE {

    take:
    ch_tables        // channel: [ val(setmeta), [ step-4 tables of the run donors ], [ reference donor tables ] ]  one per region
    donors           // list: run donors (params.donors)
    reference_donors // list: reference donor names, in the order of the reference tables

    main:
    def ch_in = ch_tables.multiMap { s, tables, refs ->
        tables: [s, tables, refs]
        region: s.interval
    }
    MARKER_UNION(ch_in.tables, donors, reference_donors, ch_in.region)

    emit:
    union     = MARKER_UNION.out.union     // channel: [ val(setmeta), <set>.<label>.tsv.gz ]
    sites     = MARKER_UNION.out.sites     // channel: [ val(setmeta), <set>.<label>.union_sites.tsv ]
    per_donor = MARKER_UNION.out.per_donor // channel: [ val(setmeta), <set>.<label>.per_donor.tsv ]
    versions  = MARKER_UNION.out.versions  // channel: versions.yml
}
