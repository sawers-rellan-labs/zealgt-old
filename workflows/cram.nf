/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CRAM workflow: raw libraries -> analysis-ready CRAMs + QC + provenance + demux registry (docs/PLAN_pipeline.md §0, §3)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Two stages with a published FASTQ checkpoint between them (nextflow-cache skill: a fix to stage 2 never reruns stage 1):
    --entry read_demultiplexing --libraries <lib>  stage 1: DEMUX -> MERGE_LANES -> DEMUX_QC -> TRIMMOMATIC (-> checkpoint
                                                   <fastq_checkpoint>/<lib>/: hardlinked trimmed pairs + samplesheet.csv)
                                                   -> FASTQC, then stage 2 in the same run on TRIMMOMATIC's output channel
    --entry read_alignment --libraries <lib>       stage 2 alone, from <fastq_checkpoint>/<lib>/samplesheet.csv: ALIGN_MARKDUP
                                                   -> SAMTOOLS_STATS + PICARD -> PROVENANCE -> REGISTRY
    --entry markdup_import [--import_sheet <csv>]  existing CRAMs (meta/dev_import.csv) -> MARKDUP_IMPORT -> QC
    All end at the CRAM stop point (§3): CRAM + QC + provenance in the store (params.store), MultiQC per library (published).
    Store outputs are published (copied, never overwritten; conf/modules.config); this workflow skips work whose stored
    output exists: a sample whose CRAM is stored and verified (zgIsStored) is not aligned again, a library whose demux QC /
    registry entry is stored gets no DEMUX_QC / REGISTRY task, stored QC and provenance are not made again.
    Inputs come from PIPELINE_INITIALISATION (sheets validated and parsed by nf-schema, registry / store / run guards
    applied there); this file only wires channels.
----------------------------------------------------------------------------------------
*/
include { READ_DEMULTIPLEXING     } from '../subworkflows/local/read_demultiplexing'
include { READ_TRIMMING           } from '../subworkflows/local/read_trimming'
include { READ_ALIGNMENT          } from '../subworkflows/local/read_alignment'
include { CRAM_IMPORT             } from '../subworkflows/local/cram_import'
include { REGISTRY                } from '../modules/local/registry/main'
include { MULTIQC                 } from '../modules/nf-core/multiqc/main'
include { softwareVersionsToYAML  } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { zgSubsample             } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgCodeVersion           } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgIsStored              } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgIsRegistered          } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStoredCram            } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStoredQc              } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStoredDemuxQc         } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgToolVersionsString    } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStage1Tools           } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgWithStage1Tools       } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgWriteCheckpointSheet  } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgLibraryGate           } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgAdmitLibrary          } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgReleaseLibrary        } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'

workflow CRAM {

    take:
    ch_libraries   // channel: [ val(lmeta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]  (read_demultiplexing)
    ch_checkpoint  // channel: [ val(meta), val(checkpoint row) ]  every sample of the stage-2 libraries (read_demultiplexing, read_alignment)
    ch_imports     // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]  (markdup_import)
    ch_records     // channel: [ val(sample_id), val(provenance record) ]
    multiqc_config // string: path, or null for assets/multiqc_config.yml
    multiqc_logo   // string: path, or null
    outdir         // string: params.outdir

    main:
    log.info("zealgt CRAM workflow: entry=${params.entry} store=${params.store} subsample=${zgSubsample()}" +
             (params.entry == 'markdup_import' ? '' : " fastq_checkpoint=${params.fastq_checkpoint}"))
    def store  = params.store
    def fasta  = file(params.fasta, checkIfExists: true)
    def ch_ref = channel.value([[id: fasta.baseName], fasta, file("${fasta}.fai", checkIfExists: true),
                                [file("${fasta}.l2b", checkIfExists: true), file("${fasta}.mbw", checkIfExists: true)]])
    def ch_qc  = channel.empty() // [ val(meta), QC file ], grouped by meta.qc_group for MultiQC

    if (params.entry == 'markdup_import') {
        def dir = "${store}/cram_import"
        def ch_input = ch_imports.branch { meta, _cram, _index, _rg -> stored: zgIsStored(dir, meta.id); todo: true }
        CRAM_IMPORT(
            ch_input.todo,
            ch_input.stored.map { meta, _cram, _index, _rg -> zgStoredCram(dir, meta, 'markdup_import') },
            ch_ref,
            ch_records,
            ch_imports.map { meta, _cram, _index, _rg -> zgStoredQc(dir, meta.id) },
        )
        ch_qc = CRAM_IMPORT.out.qc
    }
    else {
        def ch_reads    = channel.empty() // [ val(meta), [ trimmed R1, R2 ] ]  every sample of the libraries
        def ch_rec      = ch_records      // [ sample_id, provenance record ]
        def ch_demux_qc = channel.empty() // [ val(lmeta), <library>.tsv ]  (REGISTRY)
        def gate        = null            // library admission semaphore (read_demultiplexing)
        if (params.entry == 'read_demultiplexing') {
            //
            // STAGE 1: demultiplex, trim, publish the FASTQ checkpoint. At most --max_libraries libraries in flight: a library
            // enters DEMUX only when a place is free (zgAdmitLibrary), and frees it when its last CRAM leaves stage 2 below.
            //
            gate = zgLibraryGate()
            READ_DEMULTIPLEXING(
                ch_libraries.map { library -> zgAdmitLibrary(gate, library) },
                ch_libraries.map { lmeta, _r1, _r2, _barcodes, _rs, _tm -> zgStoredDemuxQc(store, lmeta.id) },
                zgSubsample(),
            )
            // per-sample FASTQ pairs (DEMUX writes <sample>_R{1,2}.fastq.gz for every sample); every sample is trimmed, so the
            // checkpoint always holds the whole library
            def ch_fastq = READ_DEMULTIPLEXING.out.reads
                .flatMap { _lmeta, fastqs -> fastqs.groupBy { f -> f.name - ~/_R[12]\.fastq\.gz$/ }.collect { id, fs -> [id, fs.sort { f -> f.name }] } }
                .join(ch_checkpoint.map { meta, _row -> [meta.id, meta] }, failOnMismatch: true)
                .map { _id, fastqs, meta -> [meta, fastqs] }
            READ_TRIMMING(ch_fastq, channel.value(file(params.trim_adapters, checkIfExists: true)))

            // tool versions of the tools that made the checkpoint FASTQs (zgStage1Tools: DEMUX's and TRIMMOMATIC's), as
            // "tool=version;..." for the samplesheet and every provenance record. Taken as soon as each tool has reported once
            // (one environment per process, so every task reports the same), not at the end of the channel: a library's
            // samplesheet must not wait for the stage 1 of the libraries admitted after it.
            def ch_stage1_tools = READ_DEMULTIPLEXING.out.versions
                .mix(READ_TRIMMING.out.versions)
                .map { _process, tool, version -> [tool, version] }
                .filter { tool, _version -> tool in zgStage1Tools() }
                .unique()
                .take(zgStage1Tools().size())
                .toList()
                .map { tools -> zgToolVersionsString(tools) }

            // checkpoint samplesheet of a library once ALL its samples are trimmed (TRIMMOMATIC's publishDir hardlinks the
            // pairs to the row's fastq_1 / fastq_2; stage 2 below reads the channel, never the published files)
            def ch_lib_rows = ch_checkpoint.map { meta, row -> [meta.library, row] }.groupTuple()
            READ_TRIMMING.out.reads
                .map { meta, _reads -> [meta.library, meta.id] }
                .combine(ch_lib_rows, by: 0)
                .map { lib, id, rows -> [groupKey(lib, rows.size()), id] }
                .groupTuple()
                .map { lib, _ids -> lib.toString() }
                .join(ch_lib_rows)
                .combine(ch_stage1_tools)
                .subscribe { _lib, rows, tools -> zgWriteCheckpointSheet(rows.collect { row -> row + [stage1_tool_versions: tools] }) }

            ch_reads    = READ_TRIMMING.out.reads
            ch_rec      = ch_records.combine(ch_stage1_tools).map { id, record, tools -> [id, zgWithStage1Tools(record, tools)] }
            ch_demux_qc = READ_DEMULTIPLEXING.out.demux_qc
            ch_qc       = READ_DEMULTIPLEXING.out.report.mix(READ_TRIMMING.out.qc)
        }
        else {
            // read_alignment: stage 2 alone, from the checkpoint samplesheets (validated by nf-schema at initialisation)
            ch_reads    = ch_checkpoint.map { meta, row -> [meta, [file(row.fastq_1), file(row.fastq_2)]] }
            ch_demux_qc = ch_checkpoint
                .map { meta, _row -> meta.library }
                .unique()
                .map { lib -> [[id: lib, library: lib], file("${store}/demux_qc/${lib}.tsv")] }
                .filter { _lmeta, tsv -> tsv.exists() }
        }

        //
        // STAGE 2: align the samples whose CRAM is not stored, QC + provenance of every sample, registry per library
        //
        def dir = "${store}/cram"
        def ch_sample = ch_checkpoint.branch { meta, _row -> stored: zgIsStored(dir, meta.id); todo: true }
        ch_sample.stored.subscribe { meta, _row -> log.info("zealgt: ${meta.id} already in ${dir}, not aligned again") }
        def ch_align = ch_reads
            .map { meta, reads -> [meta.id, meta, reads] }
            .join(ch_sample.todo.map { meta, _row -> [meta.id, true] })
            .map { _id, meta, reads, _todo -> [meta, reads] }
        READ_ALIGNMENT(
            ch_align,
            ch_checkpoint.map { meta, row -> [meta.id, row.read_group] },
            ch_sample.stored.map { meta, _row -> zgStoredCram(dir, meta, 'align_markdup') },
            ch_ref,
            ch_rec,
            ch_checkpoint.map { meta, _row -> zgStoredQc(dir, meta.id) },
        )
        ch_qc = ch_qc.mix(READ_ALIGNMENT.out.qc)

        //
        // REGISTRY: one entry per library once its demux QC table and ALL its sample CRAMs are there (not if registered)
        //
        def ch_lib_samples = ch_checkpoint.map { meta, _row -> [meta.library, meta.id] }.groupTuple()
        def ch_lib_crams = READ_ALIGNMENT.out.cram
            .map { meta, cram, crai -> [meta.library, [cram, crai]] }
            .combine(ch_lib_samples, by: 0)
            .map { lib, files, ids -> [groupKey(lib, ids.size()), files] }
            .groupTuple()
            .map { lib, files -> [lib.toString(), files.flatten()] }
        if (gate) {
            ch_lib_crams.subscribe { lib, _files -> zgReleaseLibrary(gate, lib) }
        }
        def ch_registry = ch_demux_qc
            .map { lmeta, tsv -> [lmeta.id, lmeta, tsv] }
            .join(ch_lib_crams)
            .join(ch_lib_samples)
            .branch { lib, _lmeta, _tsv, _crams, _ids -> registered: zgIsRegistered(store, lib); todo: true }
        ch_registry.registered.subscribe { lib, _lmeta, _tsv, _crams, _ids -> log.info("zealgt: library ${lib} already in ${store}/registry") }
        REGISTRY(
            ch_registry.todo.map { _lib, lmeta, tsv, crams, ids -> [lmeta, tsv, crams, ids] },
            store,
            params.run_id ?: '',
            zgCodeVersion(),
            zgSubsample(),
        )
    }

    //
    // Collate and save software versions (template): topic tuples and versions.yml files
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry_v ->
            versions_file: entry_v instanceof Path
            versions_tuple: true
        }
    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version -> [process[process.lastIndexOf(':') + 1..-1], "  ${tool}: ${version}"] }
        .groupTuple(by: 0)
        .map { process, tool_versions -> "${process}:\n${tool_versions.unique().sort().join('\n')}" }
    def ch_collated_versions = softwareVersionsToYAML(topic_versions.versions_file)
        .mix(topic_versions_string)
        .collectFile(storeDir: "${outdir}/pipeline_info", name: 'zealgt_software_mqc_versions.yml', sort: true, newLine: true)

    //
    // MODULE: MultiQC, one report per library (import set for markdup_import)
    //
    def mqc_config = file(multiqc_config ?: "${projectDir}/assets/multiqc_config.yml", checkIfExists: true)
    def mqc_logo   = multiqc_logo ? file(multiqc_logo, checkIfExists: true) : []
    def ch_mqc = ch_qc
        .map { meta, f -> [meta.qc_group ?: meta.id, f] }
        .groupTuple()
        .combine(ch_collated_versions)
        .map { group, files, versions -> [[id: group], files.flatten() + [versions], mqc_config, mqc_logo, [], []] }
    MULTIQC(ch_mqc)

    emit:
    multiqc_report = MULTIQC.out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
}
