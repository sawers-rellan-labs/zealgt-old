//
// READ_DEMULTIPLEXING (PLAN §3 row 1): one DEMUX task per library -> per-library demux QC in the store -> per-sample FASTQs.
// FETCH_LIBRARY of the plan is DEMUX's input stage (lanes / tar members streamed in place, nothing copied).
//
include { DEMUX    } from '../../../modules/local/demux/main'
include { DEMUX_QC } from '../../../modules/local/demux_qc/main'

workflow READ_DEMULTIPLEXING {

    take:
    ch_libraries  // channel: [ val(meta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]  (meta.id = library)
    val_subsample // integer: read pairs per library, 0 = all

    main:
    DEMUX(ch_libraries, val_subsample)

    def ch_barcodes = ch_libraries.map { meta, _r1, _r2, barcodes, _structures, _members -> [meta.id, barcodes] }
    def ch_qc_in = DEMUX.out.json
        .join(DEMUX.out.log)
        .join(DEMUX.out.reads)
        .map { meta, json, report, reads -> [meta.id, meta, json, report, reads] }
        .join(ch_barcodes)
        .map { _id, meta, json, report, reads, barcodes -> [meta, json, report, reads, barcodes] }
    DEMUX_QC(ch_qc_in, val_subsample)

    emit:
    reads    = DEMUX.out.reads      // channel: [ val(library meta), [ <sample>_R{1,2}.fastq.gz ... ] ]
    report   = DEMUX.out.log        // channel: [ val(library meta), cutadapt report ]
    demux_qc = DEMUX_QC.out.tsv     // channel: [ val(library meta), <library>.tsv (store) ]
    summary  = DEMUX_QC.out.summary // channel: [ val(library meta), <library>.summary.tsv (store) ]
    versions = DEMUX.out.versions_cutadapt.mix(DEMUX.out.versions_pigz, DEMUX.out.versions_tar) // channel: [ process, tool, version ]
}
