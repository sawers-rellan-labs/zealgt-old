/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CRAM workflow: raw libraries -> analysis-ready CRAMs + QC + provenance + demux registry (docs/PLAN_pipeline.md §0, §3)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    --entry read_demultiplexing  --libraries <lib>   DEMUX -> DEMUX_QC -> TRIMMOMATIC -> FASTQC -> ALIGN_MARKDUP -> QC -> REGISTRY
    --entry read_trimming        --input <sheet>     demuxed FASTQs -> TRIMMOMATIC -> FASTQC -> ALIGN_MARKDUP -> QC
    --entry read_alignment       --input <sheet>     trimmed FASTQs -> ALIGN_MARKDUP -> QC
    --entry markdup_import       [--input <sheet>]   existing CRAMs (meta/dev_import.csv) -> MARKDUP_IMPORT -> QC
    Every entry ends at the CRAM stop point (§3): CRAM + QC + provenance in the store, MultiQC per library (published).
    The store root is params.store (or <store>/subsample_<N> with --subsample, <outdir>/store_stub in stub runs).
    §0 is law: a library in the registry (assets/registry_seed.csv + <store>/registry) is refused unless --force_demux <lib>;
    one library per run (--max_libraries, default 1); samples whose CRAM is already stored are not trimmed or aligned again.
----------------------------------------------------------------------------------------
*/
include { READ_DEMULTIPLEXING    } from '../subworkflows/local/read_demultiplexing'
include { READ_TRIMMING          } from '../subworkflows/local/read_trimming'
include { READ_ALIGNMENT         } from '../subworkflows/local/read_alignment'
include { CRAM_IMPORT            } from '../subworkflows/local/cram_import'
include { REGISTRY               } from '../modules/local/registry/main'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { samplesheetToList      } from 'plugin/nf-schema'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { zgStoreRoot            } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgSubsample            } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgMaxLibraries         } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgCodeVersion          } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgLoadSamples          } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgSampleMeta           } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgReadGroup            } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgPlatformUnit         } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'
include { zgRegisteredLibraries  } from '../subworkflows/local/utils_nfcore_zealgt_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow CRAM {

    take:
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir

    main:
    def root         = zgStoreRoot()
    def code_version = zgCodeVersion()
    def entry        = params.entry
    def subsample    = zgSubsample()
    log.info("zealgt CRAM workflow: entry=${entry} store=${root} code=${code_version} subsample=${subsample}")

    def fasta = file(params.fasta, checkIfExists: true)
    def ch_ref = channel.value([
        [id: fasta.baseName],
        fasta,
        file("${params.fasta}.fai", checkIfExists: true),
        [file("${params.fasta}.l2b", checkIfExists: true), file("${params.fasta}.mbw", checkIfExists: true)],
    ])

    // Settings recorded in every provenance record (PLAN §3 stop point); the values the modules run with.
    def settings = [
        reference     : params.fasta,
        code_version  : code_version,
        pipeline      : "${workflow.manifest.name} ${workflow.manifest.version}",
        entry         : entry,
        run_id        : params.run_id ?: '',
        run_name      : workflow.runName,
        session_id    : "${workflow.sessionId}",
        profile       : workflow.profile,
        mapq_filter   : 'none (applied by the genotype workflow at read time)',
        markdup       : "samtools markdup ${params.markdup_args}",
    ]

    def ch_qc              = channel.empty() // [ qc_group, file ]
    def ch_extra_versions  = channel.empty() // [ sample_id, [ versions.yml ] ]

    if (entry == 'markdup_import') {
        //
        // Existing CRAMs -> MARKDUP_IMPORT pass (dev_import.csv; read_groups column ignored, decided from the header)
        //
        def sheet = params.input ?: "${projectDir}/meta/dev_import.csv"
        def wanted_samples = params.import_samples ? params.import_samples.tokenize(',')*.trim() : []
        def wanted_sets    = params.import_sets ? params.import_sets.tokenize(',')*.trim() : []
        def rows = samplesheetToList(sheet, "${projectDir}/assets/schema_import.json")
            .collect { meta, path, index -> [meta, file(path), file(index)] }
            .findAll { meta, _p, _i -> meta.include }
            .findAll { meta, _p, _i -> !wanted_samples || meta.id in wanted_samples }
            .findAll { meta, _p, _i -> !wanted_sets || meta.import_set in wanted_sets }
        def missing = wanted_samples - rows.collect { r -> r[0].id }
        if (missing) {
            error("--import_samples not in ${sheet} (or include = FALSE): ${missing}")
        }
        if (!rows) {
            error("markdup_import: no rows selected from ${sheet}")
        }
        def metas = rows.collect { meta, path, _index ->
            def lib = meta.library ?: meta.import_set
            meta + [
                sample     : meta.id,
                library    : lib,
                qc_group   : meta.import_set,
                single_end : false,
                read_group : zgReadGroup(meta.id, lib, 'ILLUMINA', ''),
                input_path : path.toString(),
            ]
        }
        def stored_dir = "${root}/cram_import"
        def ch_rows = channel.fromList([metas, rows].transpose().collect { m, r -> [m, r[1], r[2]] })
        def ch_import = ch_rows.filter { m, _p, _i -> !zgIsStored(stored_dir, m.id) }
        def ch_stored = ch_rows.filter { m, _p, _i -> zgIsStored(stored_dir, m.id) }
            .map { m, _p, _i ->
                def v = file("${stored_dir}/${m.id}.markdup_import.versions.yml")
                [m, file("${stored_dir}/${m.id}.cram"), file("${stored_dir}/${m.id}.cram.crai"), v.exists() ? [v] : []]
            }
        def ch_record = channel.fromList(metas).map { m ->
            [m.id, settings + [
                sample      : m.id,
                library     : m.library,
                source      : m.source ?: '',
                role        : m.role ?: '',
                donor       : m.donor ?: '',
                store_dir   : stored_dir,
                origin      : [kind: 'import', path: m.input_path, made_by: m.made_by ?: '', note: m.note ?: '',
                               input_filters: 'as made by zealbc1 / nilhmm (minibwa -x sr, MAPQ 20, -F 0x904)'],
                read_group  : 'from the input header if it has exactly one @RG, else the sample sheet (see <sample>.read_group.txt)',
            ], []]
        }
        CRAM_IMPORT(ch_import, ch_stored, ch_ref, ch_record, stored_dir)
        ch_qc = ch_qc.mix(CRAM_IMPORT.out.qc)
    }
    else {
        def samples = zgLoadSamples(params.samples)
        def ch_fastq = channel.empty()   // [ meta, [R1, R2] ] demultiplexed, untrimmed
        def ch_trimmed = channel.empty() // [ meta, [R1, R2] ] trimmed
        def sample_metas = []            // every sample of this run, [meta]
        def origin = [:]                 // sample_id -> origin map for provenance

        if (entry == 'read_demultiplexing') {
            //
            // Registry check (PLAN §0 Task 2): refuse registered libraries unless --force_demux <lib>
            //
            def libs    = params.libraries.tokenize(',')*.trim().unique()
            def force   = params.force_demux ? params.force_demux.tokenize(',')*.trim() : []
            def unknown_force = force - libs
            if (unknown_force) {
                error("--force_demux names libraries that are not in --libraries: ${unknown_force}")
            }
            if (libs.size() > zgMaxLibraries()) {
                error("${libs.size()} libraries requested, --max_libraries ${params.max_libraries}: one library in flight (PLAN §5 rule 3)")
            }
            def registered = zgRegisteredLibraries()
            def refused = libs.findAll { l -> registered.containsKey(l) && !(l in force) }
            if (refused) {
                error("refusing to demultiplex registered libraries ${refused.collect { l -> "${l} [${registered[l]}]" }} (PLAN §0 Task 2); name them with --force_demux to override")
            }
            libs.findAll { l -> l in force }.each { l -> log.warn("--force_demux ${l}: demultiplexing a registered library (${registered[l] ?: 'not registered'})") }

            def libraries = libs.collect { lib ->
                def rows = samples.values().findAll { r -> r.library == lib }
                if (!rows) {
                    error("library ${lib} has no samples in ${params.samples}")
                }
                def first = rows[0]
                ['source', 'barcode_layout', 'raw_location', 'raw_r1', 'raw_r2'].each { k ->
                    if (rows.collect { r -> r[k] }.unique().size() != 1) {
                        error("library ${lib}: samples disagree on ${k}")
                    }
                }
                def structures = (first.barcode_layout == 'symmetric' ? params.read_structure_symmetric : params.read_structure_r1_only).tokenize(' ')
                if (structures.size() != 2) {
                    error("read structure for ${first.barcode_layout} must be two tokens '<R1> <R2>', got '${structures.join(' ')}'")
                }
                def r1 = []
                def r2 = []
                def members_r1 = []
                def members_r2 = []
                if (first.raw_r1) {
                    // batch-1 plate pools: "<tar>:<member>;<tar>:<member>" relative to raw_location, one tar per read
                    def t1 = zgTarMembers(first.raw_r1)
                    def t2 = zgTarMembers(first.raw_r2)
                    if (t1.collect { t -> t[0] }.unique().size() != 1 || t2.collect { t -> t[0] }.unique().size() != 1 || t1.size() != t2.size()) {
                        error("library ${lib}: raw_r1/raw_r2 must name one tar each with the same number of members")
                    }
                    r1 = [file("${first.raw_location}/${t1[0][0]}", checkIfExists: true)]
                    r2 = [file("${first.raw_location}/${t2[0][0]}", checkIfExists: true)]
                    members_r1 = t1.collect { t -> t[1] }
                    members_r2 = t2.collect { t -> t[1] }
                }
                else {
                    r1 = files("${first.raw_location}/${params.raw_r1_glob}").sort { f -> f.name }
                    r2 = files("${first.raw_location}/${params.raw_r2_glob}").sort { f -> f.name }
                    if (!r1 || r1.size() != r2.size()) {
                        error("library ${lib}: ${r1.size()} R1 and ${r2.size()} R2 files match ${params.raw_r1_glob} / ${params.raw_r2_glob} in ${first.raw_location}")
                    }
                    [r1, r2].transpose().each { a, b ->
                        if (a.name.replaceFirst(/_1(\.f(ast)?q\.gz)$/, '') != b.name.replaceFirst(/_2(\.f(ast)?q\.gz)$/, '')) {
                            error("library ${lib}: R1/R2 files do not pair: ${a.name} ${b.name}")
                        }
                    }
                }
                def pu = zgPlatformUnit(r1.collect { f -> f.name })
                def lmeta = [
                    id                : lib,
                    library           : lib,
                    source            : first.source,
                    layout            : first.barcode_layout,
                    read_structure_r1 : structures[0],
                    read_structure_r2 : structures[1],
                    tar_members_r1    : members_r1,
                    tar_members_r2    : members_r2,
                    n_samples         : rows.size(),
                    pu                : pu,
                ]
                def barcodes = rows.collect { r -> [r.sample_id, r.barcode_r1, r.barcode_r2 ?: ''] }
                rows.each { r ->
                    sample_metas << zgSampleMeta(r, pu)
                    origin[r.sample_id] = [kind: 'demux', library: lib, raw_location: first.raw_location,
                                           raw_files_r1: r1.collect { f -> f.name }, raw_files_r2: r2.collect { f -> f.name },
                                           tar_members_r1: members_r1, tar_members_r2: members_r2,
                                           tool: 'cutadapt', args: params.demux_args,
                                           read_structure: "${structures[0]} ${structures[1]}", layout: first.barcode_layout,
                                           barcode_r1: r.barcode_r1, barcode_r2: r.barcode_r2 ?: '', subsample: subsample]
                }
                [lmeta, r1, r2, barcodes]
            }

            READ_DEMULTIPLEXING(channel.fromList(libraries), subsample)
            ch_qc = ch_qc.mix(READ_DEMULTIPLEXING.out.report.map { lmeta, f -> [lmeta.id, f] })

            def by_id = sample_metas.collectEntries { m -> [m.id, m] }
            ch_fastq = READ_DEMULTIPLEXING.out.reads.flatMap { lmeta, fastqs ->
                fastqs.groupBy { f -> f.name.replaceFirst(/_R[12]\.fastq\.gz$/, '') }.collect { sid, fs ->
                    if (!by_id.containsKey(sid)) {
                        error("DEMUX ${lmeta.id} wrote reads for ${sid}, which is not a sample of that library")
                    }
                    [by_id[sid], fs.sort { f -> f.name }]
                }
            }
            // DEMUX versions.yml of the library go into each of its samples' provenance record
            ch_extra_versions = READ_DEMULTIPLEXING.out.versions
                .flatMap { lmeta, v -> sample_metas.findAll { m -> m.library == lmeta.id }.collect { m -> [m.id, [v]] } }
        }
        else {
            //
            // FASTQ sheet (assets/schema_input.json): demuxed (read_trimming) or trimmed (read_alignment) pairs
            //
            def rows = samplesheetToList(params.input, "${projectDir}/assets/schema_input.json")
            // Pre-demuxed FASTQs must declare the non-genomic 5' bases they still carry (crop_r1 / crop_r2). Cropping
            // is not implemented, so anything but 0 / 0 is refused: primer / randomer bases are never aligned silently.
            def uncropped = rows.findAll { meta, _fq1, _fq2 -> meta.crop_r1 || meta.crop_r2 }
            if (uncropped) {
                error("${params.input}: samples still carry non-genomic 5' bases (crop_r1 / crop_r2 > 0), and zealgt does not crop pre-demuxed FASTQs yet: ${uncropped.collect { r -> "${r[0].id} (${r[0].crop_r1}/${r[0].crop_r2})" }}")
            }
            def pairs = rows.collect { meta, fq1, fq2 ->
                def r = samples[meta.id]
                if (!r) {
                    error("sample ${meta.id} of ${params.input} is not in ${params.samples}")
                }
                def m = zgSampleMeta(r, '')
                sample_metas << m
                origin[m.id] = [kind: entry == 'read_trimming' ? 'fastq_demuxed' : 'fastq_trimmed', sheet: params.input,
                                fastq_1: fq1.toString(), fastq_2: fq2.toString(), crop_r1: meta.crop_r1, crop_r2: meta.crop_r2]
                [m, [file(fq1), file(fq2)]]
            }
            if (entry == 'read_trimming') {
                ch_fastq = channel.fromList(pairs)
            }
            else {
                ch_trimmed = channel.fromList(pairs)
            }
        }

        //
        // Samples whose CRAM is already stored skip trimming and alignment (the workflow computes only what is missing)
        //
        def stored_dir = "${root}/cram"
        def ch_stored = channel.fromList(sample_metas.findAll { m -> zgIsStored(stored_dir, m.id) }).map { m ->
            def v = file("${stored_dir}/${m.id}.align_markdup.versions.yml")
            [m, file("${stored_dir}/${m.id}.cram"), file("${stored_dir}/${m.id}.cram.crai"), v.exists() ? [v] : []]
        }
        sample_metas.findAll { m -> zgIsStored(stored_dir, m.id) }.each { m -> log.info("zealgt: ${m.id} already in ${stored_dir}, not aligned again") }

        def ch_trim_version = channel.value('not run')
        if (entry in ['read_demultiplexing', 'read_trimming']) {
            READ_TRIMMING(ch_fastq.filter { m, _r -> !zgIsStored(stored_dir, m.id) })
            ch_trimmed = READ_TRIMMING.out.reads
            ch_qc = ch_qc.mix(READ_TRIMMING.out.qc)
            ch_trim_version = READ_TRIMMING.out.trim_version.ifEmpty('not run in this session')
        }
        else {
            ch_trimmed = ch_trimmed.filter { m, _r -> !zgIsStored(stored_dir, m.id) }
        }

        def ch_record = channel.fromList(sample_metas)
            .combine(ch_trim_version)
            .map { m, trim_version ->
                [m.id, m, settings + [
                    sample     : m.id,
                    library    : m.library,
                    source     : m.source ?: '',
                    role       : m.role ?: '',
                    donor      : m.donor ?: '',
                    store_dir  : stored_dir,
                    origin     : origin[m.id],
                    trimming   : entry == 'read_alignment' ? 'not done by zealgt (trimmed FASTQs given)' :
                                 [tool: "trimmomatic", version: trim_version, illuminaclip: params.trim_illuminaclip, args: params.trim_args, adapters: params.trim_adapters,
                                  phred: 'auto-detected'],  // no -phred33: nf-core TRIMMOMATIC appends ext.args after the outputs
                    alignment  : [tool: 'minibwa map', args: params.align_args, read_group: m.read_group],
                ]]
            }
            .join(ch_extra_versions, remainder: true)
            .filter { row -> row[1] != null }
            .map { id, _m, record, extra -> [id, record, extra ?: []] }

        READ_ALIGNMENT(ch_trimmed, ch_stored, ch_ref, ch_record, stored_dir)
        ch_qc = ch_qc.mix(READ_ALIGNMENT.out.qc)

        if (entry == 'read_demultiplexing') {
            //
            // REGISTRY: one entry per library once its demux QC table and ALL its sample CRAMs are in the store
            //
            def n_by_lib = sample_metas.countBy { m -> m.library }
            def ch_crams = READ_ALIGNMENT.out.cram
                .map { m, cram, crai -> [groupKey(m.library, n_by_lib[m.library]), [cram, crai]] }
                .groupTuple()
                .map { lib, files -> [lib.toString(), files.flatten()] }
            def ch_reg = READ_DEMULTIPLEXING.out.demux_qc
                .map { lmeta, tsv -> [lmeta.id, lmeta, tsv] }
                .join(ch_crams, failOnMismatch: true)
                .map { lib, lmeta, tsv, crams -> [lmeta, tsv, crams, sample_metas.findAll { m -> m.library == lib }.collect { m -> m.id }] }
            REGISTRY(ch_reg, root, params.run_id ?: '', code_version, subsample)
        }
    }

    //
    // Collate and save software versions (template)
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry_v ->
            versions_file: entry_v instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(topic_versions.versions_file)
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'zealgt_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    //
    // MODULE: MultiQC, one report per library (import set for markdup_import)
    //
    def mqc_config = multiqc_config
        ? file(multiqc_config, checkIfExists: true)
        : file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true)
    def mqc_logo = multiqc_logo ? file(multiqc_logo, checkIfExists: true) : []
    def ch_mqc = ch_qc
        .groupTuple()
        .combine(ch_collated_versions)
        .map { group, files, versions -> [[id: group], files.flatten() + [versions], mqc_config, mqc_logo, [], []] }
    MULTIQC(ch_mqc)

    emit:
    multiqc_report = MULTIQC.out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// A sample counts as stored when its CRAM and index are in the store directory (storeDir would skip it anyway).
def zgIsStored(String dir, String id) {
    return file("${dir}/${id}.cram").exists() && file("${dir}/${id}.cram.crai").exists()
}

// batch-1 raw spec "<tar>:<member>;<tar>:<member>" -> [[tar, member], ...]
def zgTarMembers(String spec) {
    return spec.tokenize(';').collect { s ->
        def i = s.indexOf(':')
        [s.substring(0, i), s.substring(i + 1)]
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
