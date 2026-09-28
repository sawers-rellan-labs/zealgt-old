/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CRAM workflow: raw libraries -> analysis-ready CRAMs + QC + provenance + demux registry (docs/PLAN_pipeline.md §0, §3)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    --entry read_demultiplexing --libraries <lib>  DEMUX -> DEMUX_QC -> TRIMMOMATIC -> FASTQC -> ALIGN_MARKDUP -> QC -> REGISTRY
    --entry markdup_import [--import_sheet <csv>]  existing CRAMs (meta/dev_import.csv) -> MARKDUP_IMPORT -> QC
    Both end at the CRAM stop point (§3): CRAM + QC + provenance in the store (params.store), MultiQC per library (published).
    Inputs come from PIPELINE_INITIALISATION (sheets validated and parsed by nf-schema, registry / run guards applied there);
    this file only wires channels. Samples whose CRAM is already stored are not trimmed or aligned again.
----------------------------------------------------------------------------------------
*/
include { READ_DEMULTIPLEXING    } from '../subworkflows/local/read_demultiplexing'
include { READ_TRIMMING          } from '../subworkflows/local/read_trimming'
include { READ_ALIGNMENT         } from '../subworkflows/local/read_alignment'
include { CRAM_IMPORT            } from '../subworkflows/local/cram_import'
include { REGISTRY               } from '../modules/local/registry/main'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { zgSubsample            } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgCodeVersion          } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgIsStored             } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStoredCram           } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgStoredQc             } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'

workflow CRAM {

    take:
    ch_libraries   // channel: [ val(lmeta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]
    ch_samples     // channel: [ val(meta), val(read_group) ]  every sample of the run (read_demultiplexing)
    ch_imports     // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]  (markdup_import)
    ch_records     // channel: [ val(sample_id), val(provenance record) ]
    multiqc_config // string: path, or null for assets/multiqc_config.yml
    multiqc_logo   // string: path, or null
    outdir         // string: params.outdir

    main:
    log.info("zealgt CRAM workflow: entry=${params.entry} store=${params.store} subsample=${zgSubsample()}")
    def fasta  = file(params.fasta, checkIfExists: true)
    def ch_ref = channel.value([[id: fasta.baseName], fasta, file("${fasta}.fai", checkIfExists: true),
                                [file("${fasta}.l2b", checkIfExists: true), file("${fasta}.mbw", checkIfExists: true)]])
    def ch_qc  = channel.empty() // [ val(meta), QC file ], grouped by meta.qc_group for MultiQC

    if (params.entry == 'markdup_import') {
        def dir = "${params.store}/cram_import"
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
        def dir = "${params.store}/cram"
        def ch_sample = ch_samples.branch { meta, _rg -> stored: zgIsStored(dir, meta.id); todo: true }
        ch_sample.stored.subscribe { meta, _rg -> log.info("zealgt: ${meta.id} already in ${dir}, not aligned again") }

        READ_DEMULTIPLEXING(ch_libraries, zgSubsample())
        // per-sample FASTQ pairs of the samples still to align (DEMUX writes <sample>_R{1,2}.fastq.gz for every sample)
        def ch_fastq = READ_DEMULTIPLEXING.out.reads
            .flatMap { _lmeta, fastqs -> fastqs.groupBy { f -> f.name - ~/_R[12]\.fastq\.gz$/ }.collect { id, fs -> [id, fs.sort { f -> f.name }] } }
            .join(ch_sample.todo.map { meta, _rg -> [meta.id, meta] })
            .map { _id, fastqs, meta -> [meta, fastqs] }
        READ_TRIMMING(ch_fastq, channel.value(file(params.trim_adapters, checkIfExists: true)))

        // tool versions of this session's DEMUX / TRIMMOMATIC / FASTQC tasks go into every provenance record
        def ch_session_tools = READ_DEMULTIPLEXING.out.versions.mix(READ_TRIMMING.out.versions)
            .map { _process, tool, version -> [tool, version] }
            .unique()
            .toList()
            .map { tools -> tools.groupBy { t -> t[0] }.collectEntries { tool, vs -> [tool, vs*.getAt(1).join(',')] } }
        READ_ALIGNMENT(
            READ_TRIMMING.out.reads,
            ch_samples.map { meta, rg -> [meta.id, rg] },
            ch_sample.stored.map { meta, _rg -> zgStoredCram(dir, meta, 'align_markdup') },
            ch_ref,
            ch_records.combine(ch_session_tools).map { id, record, tools -> [id, record + [session_tool_versions: tools]] },
            ch_samples.map { meta, _rg -> zgStoredQc(dir, meta.id) },
        )
        ch_qc = READ_DEMULTIPLEXING.out.report.mix(READ_TRIMMING.out.qc, READ_ALIGNMENT.out.qc)

        //
        // REGISTRY: one entry per library once its demux QC table and ALL its sample CRAMs are in the store
        //
        def ch_lib_samples = ch_libraries.map { lmeta, _r1, _r2, barcodes, _rs, _tm -> [lmeta.id, barcodes*.getAt(0)] }
        def ch_lib_crams = READ_ALIGNMENT.out.cram
            .map { meta, cram, crai -> [meta.library, [cram, crai]] }
            .combine(ch_lib_samples, by: 0)
            .map { lib, files, ids -> [groupKey(lib, ids.size()), files] }
            .groupTuple()
            .map { lib, files -> [lib.toString(), files.flatten()] }
        def ch_registry = READ_DEMULTIPLEXING.out.demux_qc
            .map { lmeta, tsv -> [lmeta.id, lmeta, tsv] }
            .join(ch_lib_crams, failOnMismatch: true)
            .join(ch_lib_samples)
            .map { _lib, lmeta, tsv, crams, ids -> [lmeta, tsv, crams, ids] }
        REGISTRY(ch_registry, params.store, params.run_id ?: '', zgCodeVersion(), zgSubsample())
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
