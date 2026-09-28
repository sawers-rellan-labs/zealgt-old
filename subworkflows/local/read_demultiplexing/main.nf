//
// READ_DEMULTIPLEXING (PLAN §3 row 1): one DEMUX task per library x lane -> MERGE_LANES (per sample, one FASTQ pair per
// library) -> per-library demux QC in the store (DEMUX_QC sums the lane reports). Every read of the library is demultiplexed
// exactly once; the registry still records one demux pass per library.
// FETCH_LIBRARY of the plan is DEMUX's input stage (lane FASTQs read in place, batch-1 tar members extracted per lane).
//
include { DEMUX       } from '../../../modules/local/demux/main'
include { MERGE_LANES } from '../../../modules/local/merge_lanes/main'
include { DEMUX_QC    } from '../../../modules/local/demux_qc/main'

workflow READ_DEMULTIPLEXING {

    take:
    ch_libraries  // channel: [ val(meta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]  (meta.id = library)
    val_subsample // integer: read pairs per library, 0 = all (DEMUX takes ceil(N / lanes) from each lane)

    main:
    def ch_lanes = ch_libraries.flatMap { meta, r1, r2, barcodes, structures, members -> zgLibraryLanes(meta, r1, r2, barcodes, structures, members) }
    DEMUX(ch_lanes, val_subsample)

    def ch_library = ch_libraries.map { meta, _r1, _r2, barcodes, _structures, _members -> [meta.id, meta, barcodes] }
    // all lanes of a library -> [ id, [ lane json ], [ lane log ], [ lane FASTQs ] ], released as soon as its last lane is done
    def ch_demuxed = DEMUX.out.json
        .join(DEMUX.out.log)
        .join(DEMUX.out.reads)
        .map { meta, json, report, reads -> [groupKey(meta.library, meta.n_lanes), json, report, reads] }
        .groupTuple()
        .map { id, jsons, reports, reads -> [id.toString(), jsons.sort { f -> f.name }, reports.sort { f -> f.name }, reads.flatten()] }
        .join(ch_library, failOnMismatch: true)

    MERGE_LANES(ch_demuxed.map { _id, jsons, _reports, reads, meta, barcodes -> [meta, reads, barcodes, jsons.size()] })

    def ch_qc_in = ch_demuxed
        .map { id, jsons, reports, _reads, meta, barcodes -> [id, meta, jsons, reports, barcodes] }
        .join(MERGE_LANES.out.reads.map { meta, reads -> [meta.id, reads] }, failOnMismatch: true)
        .map { _id, meta, jsons, reports, barcodes, reads -> [meta, jsons, reports, reads, barcodes] }
    DEMUX_QC(ch_qc_in, val_subsample)

    emit:
    reads    = MERGE_LANES.out.reads // channel: [ val(library meta), [ <sample>_R{1,2}.fastq.gz ... ] ]
    report   = ch_demuxed.flatMap { _id, _jsons, reports, _reads, meta, _barcodes -> reports.collect { f -> [meta, f] } } // channel: [ val(library meta), cutadapt report ]  one per lane
    demux_qc = DEMUX_QC.out.tsv      // channel: [ val(library meta), <library>.tsv (store) ]
    summary  = DEMUX_QC.out.summary  // channel: [ val(library meta), <library>.summary.tsv (store) ]
    versions = DEMUX.out.versions_cutadapt.mix(DEMUX.out.versions_pigz, DEMUX.out.versions_tar) // channel: [ process, tool, version ]
}

//
// One library -> one DEMUX input per lane: [ meta + [id: <library>.<lane>, n_lanes], R1, R2, barcodes, read_structures,
// [ R1 member, R2 member ], n_lanes ]. meta.library keeps the library id (lane outputs are regrouped on it); DEMUX itself
// reads only meta.id (its prefix) and the n_lanes input.
// Lane FASTQs pair by position (sorted and name-checked in zgRawFiles); lane = the R1 file name without _1.f(ast)q.gz.
// Batch-1: one tar per read, one lane per member pair; lane = the R1 member's base name without _1 / _R1 and .f(ast)q.gz.
// Lane names are reduced to [A-Za-z0-9._-] and must be unique within the library.
//
def zgLibraryLanes(Map meta, List r1, List r2, List barcodes, List structures, List members) {
    def (m1, m2) = members
    def pairs = m1 ? [m1, m2].transpose().collect { a, b -> [r1[0], r2[0], a, b, a.tokenize('/')[-1]] }
                   : [r1, r2].transpose().collect { a, b -> [a, b, '', '', a.name] }
    def lanes = pairs.collect { a, b, ma, mb, name ->
        def lane = name.replaceFirst(/(_R?1)?\.f(ast)?q\.gz$/, '').replaceAll(/[^A-Za-z0-9._-]/, '_')
        [lane, a, b, ma, mb]
    }
    if (lanes*.getAt(0).unique().size() != lanes.size()) {
        error("library ${meta.id}: lane names are not unique: ${lanes*.getAt(0)}")
    }
    return lanes.collect { lane, a, b, ma, mb -> [meta + [id: "${meta.id}.${lane}".toString(), n_lanes: lanes.size()], a, b, barcodes, structures, [ma, mb], lanes.size()] }
}
