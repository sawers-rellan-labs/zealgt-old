//
// Subworkflow with functionality specific to the sawers-rellan-labs/zealgt pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { samplesheetToList         } from 'plugin/nf-schema'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters (and --input against assets/schema_input.json) and generate parameter summary to stdout
    //
    def before_text = ""
    def after_text = ""
    def command = "nextflow run ${workflow.manifest.name} -profile hazel,short --workflow cram --entry read_demultiplexing --libraries <LIB> --run_id <RUN> --outdir <OUTDIR>"

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command,
        false
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // zealgt run guards (conf/hazel.config, PLAN §2 / §5), then the entry's inputs from its sample sheet (nf-schema)
    //
    zgRunGuards()
    def inputs = [libraries: [], samples: [], imports: [], records: []]
    if (params.workflow == 'cram') {
        inputs = params.entry == 'markdup_import' ? zgImportInputs() : zgDemuxInputs()
    }

    emit:
    libraries = channel.fromList(inputs.libraries) // channel: [ val(lmeta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]
    samples   = channel.fromList(inputs.samples)   // channel: [ val(meta), val(read_group) ]  every sample of the run
    imports   = channel.fromList(inputs.imports)   // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]
    records   = channel.fromList(inputs.records)   // channel: [ val(sample_id), val(provenance record) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    monochrome_logs // boolean: Disable ANSI colour codes in log output

    main:

    //
    // Completion summary
    //
    workflow.onComplete {

        completionSummary(monochrome_logs)

    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs for common issues: https://nf-co.re/docs/running/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS (template): methods description for MultiQC
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Used only by the template's workflows/zealgt.nf (not included by main.nf); the CRAM workflow's MultiQC has no methods
    section. The tool list matches CITATIONS.md.
*/

def toolCitationText() {
    def citation_text = [
            "Tools used in the workflow included:",
            "cutadapt (Martin 2011),",
            "Trimmomatic (Bolger et al. 2014),",
            "FastQC (Andrews 2010),",
            "minibwa (Li, https://github.com/lh3/minibwa),",
            "SAMtools (Danecek et al. 2021),",
            "Picard (Broad Institute 2019),",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    def reference_text = [
            "<li>Martin M (2011) Cutadapt removes adapter sequences from high-throughput sequencing reads. EMBnet.journal 17(1):10-12. doi: 10.14806/ej.17.1.200</li>",
            "<li>Bolger AM, Lohse M, Usadel B (2014) Trimmomatic: a flexible trimmer for Illumina sequence data. Bioinformatics 30(15):2114-2120. doi: 10.1093/bioinformatics/btu170</li>",
            "<li>Andrews S (2010) FastQC, URL: https://www.bioinformatics.babraham.ac.uk/projects/fastqc/</li>",
            "<li>Li H. minibwa, URL: https://github.com/lh3/minibwa</li>",
            "<li>Danecek P et al. (2021) Twelve years of SAMtools and BCFtools. GigaScience 10(2):giab008. doi: 10.1093/gigascience/giab008</li>",
            "<li>Broad Institute (2019) Picard toolkit, URL: https://broadinstitute.github.io/picard/</li>",
            "<li>Ewels P, Magnusson M, Lundin S, Käller M (2016) MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics 32(19):3047-3048. doi: 10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    meta["tool_bibliography"] = toolBibliographyText()

    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ZEALGT FUNCTIONS: run guards
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Integer params (Nextflow 26 hands CLI values over as strings; the schema accepts digit strings, see nextflow_schema.json)
//
def zgSubsample() {
    return params.subsample.toString().toInteger()
}

def zgMaxLibraries() {
    return params.max_libraries.toString().toInteger()
}

// Comma-separated param -> list of trimmed, non-empty values
def zgList(value) {
    return value ? value.toString().tokenize(',')*.trim().findAll { v -> v } : []
}

//
// Guards applied before any task runs (the schema already checked types, patterns and integer ranges).
//
def zgRunGuards() {
    def profiles = workflow.profile.tokenize(',')
    if (profiles.intersect(['hazel', 'slurm']) && !params.run_id) {
        error("--run_id is required on hazel: it names the scratch dir /share/maize/frodrig4/nf_work/<run_id> (conf/hazel.config)")
    }
    def store = zgRealPath(params.store)
    // a subset never lands where the real CRAMs go (a stored subsample CRAM would make storeDir skip the real alignment)
    def subsample_dir = zgSubsample() ? "subsample_${zgSubsample()}" : ''
    if (subsample_dir && store.name != subsample_dir) {
        error("--subsample ${zgSubsample()} needs a store directory named ${subsample_dir}: --store <store>/${subsample_dir} (got ${store})")
    }
    if (!subsample_dir && store.name ==~ /subsample_\d+/) {
        error("--store ${store} is a subsample store; name it with --subsample ${store.name - 'subsample_'} (or use the full store)")
    }
    if (workflow.stubRun) {
        // the stub store must lie in a directory named store_stub* and not inside the production store
        def production = zgRealPath('/rsstu/users/r/rrellan/BZea/ZEAL/store')
        if (!store.iterator().any { p -> p.toString().startsWith('store_stub') } || store.startsWith(production)) {
            error("stub runs must not write into the real store: --store must be (inside) a directory named store_stub* outside ${production} (conf/stub.config sets <outdir>/store_stub), got ${store}")
        }
    }
    if (params.workflow == 'cram' && params.entry == 'read_demultiplexing' && !params.libraries) {
        error("--entry read_demultiplexing needs --libraries <library>[,<library>...] (meta/samples.csv 'library' column)")
    }
}

//
// Absolute path with symlinks resolved, also for a path that does not exist yet: the deepest existing ancestor is resolved
// (toRealPath) and the missing tail appended.
//
def zgRealPath(String path) {
    return zgRealPathOf(file(path).toAbsolutePath().normalize())
}

def zgRealPathOf(p) {
    if (p.exists()) {
        return p.toRealPath()
    }
    return p.parent == null ? p : zgRealPathOf(p.parent).resolve(p.name)
}

//
// read_demultiplexing request (PLAN §0 Task 2, §5 rule 3): at most --max_libraries libraries, --force_demux only names
// requested libraries, and a registered library is refused unless it is named with --force_demux.
//
def zgCheckDemuxRequest(List libs) {
    def force = zgList(params.force_demux)
    if (force - libs) {
        error("--force_demux names libraries that are not in --libraries: ${force - libs}")
    }
    if (libs.size() > zgMaxLibraries()) {
        error("${libs.size()} libraries requested, --max_libraries ${params.max_libraries}: one library in flight (PLAN §5 rule 3)")
    }
    def registered = zgRegisteredLibraries()
    def refused = libs.findAll { l -> registered.containsKey(l) && !(l in force) }
    if (refused) {
        error("refusing to demultiplex registered libraries ${refused.collect { l -> "${l} [${registered[l]}]" }} (PLAN §0 Task 2); name them with --force_demux to override")
    }
    force.each { l -> log.warn("--force_demux ${l}: demultiplexing a registered library (${registered[l] ?: 'not registered'})") }
}

//
// Libraries registered as demultiplexed: assets/registry_seed.csv (PLAN §0: the libraries demuxed before zealgt) plus
// every <store>/registry/<library>.registry.tsv.
//
def zgRegisteredLibraries() {
    def seed = file(params.registry_seed, checkIfExists: true)
    def libs = [:]
    seed.readLines().drop(1).findAll { line -> line.trim() && !line.startsWith('#') }.each { line ->
        libs[line.tokenize(',')[0].trim()] = "seed (${params.registry_seed})"
    }
    def reg = file("${params.store}/registry")
    if (reg.isDirectory()) {
        reg.listFiles().findAll { f -> f.name.endsWith('.registry.tsv') }.each { f ->
            libs[f.name.replace('.registry.tsv', '')] = "store (${f})"
        }
    }
    return libs
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ZEALGT FUNCTIONS: entry inputs from the sample sheets (nf-schema samplesheetToList)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// --entry read_demultiplexing: the --libraries rows of --input (meta/samples.csv) -> one DEMUX input per library, and per
// sample its meta, read group and provenance record. Origins and read groups stay out of `meta` (meta is hashed).
//
def zgDemuxInputs() {
    def libs = zgList(params.libraries).unique()
    zgCheckDemuxRequest(libs)
    def rows = samplesheetToList(params.input, "${projectDir}/assets/schema_input.json").collect { row -> (row instanceof List ? row[0] : row) as Map }
    def settings = zgRunSettings()
    def out = [libraries: [], samples: [], imports: [], records: []]
    libs.each { lib ->
        def lrows = rows.findAll { r -> r.library == lib }
        if (!lrows) {
            error("library ${lib} has no samples in ${params.input}")
        }
        def first = lrows[0]
        // a cross-row rule nf-schema cannot express; meta/build_samples.py checks it too
        ['source', 'barcode_layout', 'raw_location', 'raw_r1', 'raw_r2'].findAll { k -> lrows*.get(k).unique().size() != 1 }.each { k ->
            error("library ${lib}: samples disagree on ${k} in ${params.input}")
        }
        def structures = (first.barcode_layout == 'symmetric' ? params.read_structure_symmetric : params.read_structure_r1_only).tokenize(' ')
        def raw = zgRawFiles(lib, first)
        def pu = zgPlatformUnit(raw.r1*.name)
        def lmeta = [id: lib, library: lib, source: first.source, layout: first.barcode_layout, n_samples: lrows.size(), pu: pu]
        out.libraries << [lmeta, raw.r1, raw.r2, lrows.collect { r -> [r.sample_id, r.barcode_r1, r.barcode_r2 ?: ''] }, structures, [raw.members_r1, raw.members_r2]]
        lrows.each { r ->
            def meta = [id: r.sample_id, sample: r.sample_id, library: r.library, source: r.source, role: r.role ?: '',
                        donor: r.donor ?: '', taxon: r.taxon ?: '', single_end: false, qc_group: r.library]
            def read_group = zgReadGroup(r.sample_id, r.rg_lb ?: r.library, r.rg_pl, pu)
            def origin = [kind: 'demux', library: lib, raw_location: raw.location, raw_files_r1: raw.r1*.name, raw_files_r2: raw.r2*.name,
                          tar_members_r1: raw.members_r1, tar_members_r2: raw.members_r2, tool: 'cutadapt', args: params.demux_args,
                          read_structure: structures.join(' '), layout: first.barcode_layout, barcode_r1: r.barcode_r1,
                          barcode_r2: r.barcode_r2 ?: '', subsample: zgSubsample()]
            out.samples << [meta, read_group]
            out.records << [meta.id, zgProvenanceRecord(settings, meta, "${params.store}/cram", origin, read_group) + [
                trimming : [tool: 'trimmomatic', illuminaclip: params.trim_illuminaclip, args: params.trim_args,
                            adapters: params.trim_adapters, phred: 'auto-detected'], // no -phred33: nf-core TRIMMOMATIC appends ext.args after the outputs
                alignment: [tool: 'minibwa map', args: params.align_args, read_group: read_group],
            ]]
        }
    }
    return out
}

//
// Raw files of one library: lane FASTQs (params.raw_r1_glob / raw_r2_glob, paired by name) in raw_location, or for
// batch-1 plate pools one tar per read with its members ("<tar>:<member>;<tar>:<member>" in raw_r1 / raw_r2). A relative
// raw_location (tests/fixtures only, assets/schema_input.json) is resolved against the pipeline directory.
//
def zgRawFiles(String lib, Map row) {
    def location = row.raw_location.startsWith('/') ? row.raw_location : "${projectDir}/${row.raw_location}"
    if (row.raw_r1) {
        def t1 = zgTarMembers(row.raw_r1)
        def t2 = zgTarMembers(row.raw_r2 ?: '')
        if (t1*.getAt(0).unique().size() != 1 || t2*.getAt(0).unique().size() != 1 || t1.size() != t2.size()) {
            error("library ${lib}: raw_r1/raw_r2 must name one tar each with the same number of members")
        }
        return [location: location, r1: [file("${location}/${t1[0][0]}", checkIfExists: true)], r2: [file("${location}/${t2[0][0]}", checkIfExists: true)],
                members_r1: t1*.getAt(1), members_r2: t2*.getAt(1)]
    }
    def r1 = files("${location}/${params.raw_r1_glob}").sort { f -> f.name }
    def r2 = files("${location}/${params.raw_r2_glob}").sort { f -> f.name }
    if (!r1 || r1.size() != r2.size()) {
        error("library ${lib}: ${r1.size()} R1 and ${r2.size()} R2 files match ${params.raw_r1_glob} / ${params.raw_r2_glob} in ${location}")
    }
    [r1, r2].transpose().findAll { a, b -> a.name.replaceFirst(/_1(\.f(ast)?q\.gz)$/, '') != b.name.replaceFirst(/_2(\.f(ast)?q\.gz)$/, '') }.each { a, b ->
        error("library ${lib}: R1/R2 files do not pair: ${a.name} ${b.name}")
    }
    return [location: location, r1: r1, r2: r2, members_r1: [], members_r2: []]
}

// batch-1 raw spec "<tar>:<member>;<tar>:<member>" -> [[tar, member], ...]
def zgTarMembers(String spec) {
    return spec.tokenize(';').collect { s ->
        def i = s.indexOf(':')
        i > 0 ? [s.substring(0, i), s.substring(i + 1)] : error("tar member spec '${s}' is not <tar>:<member>")
    }
}

//
// --entry markdup_import: the included rows of --import_sheet (meta/dev_import.csv), optionally restricted to
// --import_samples / --import_sets -> [meta, cram, index, read_group] and provenance records. The sheet's read_groups
// column is ignored: MARKDUP_IMPORT decides from the input header.
//
def zgImportInputs() {
    def wanted_samples = zgList(params.import_samples)
    def wanted_sets    = zgList(params.import_sets)
    def rows = samplesheetToList(params.import_sheet, "${projectDir}/assets/schema_import.json")
        .findAll { meta, _path, _index -> meta.include }
        .findAll { meta, _path, _index -> !wanted_samples || meta.id in wanted_samples }
        .findAll { meta, _path, _index -> !wanted_sets || meta.import_set in wanted_sets }
    def missing = wanted_samples - rows.collect { r -> r[0].id }
    if (missing) {
        error("--import_samples not in ${params.import_sheet} (or include = FALSE): ${missing}")
    }
    if (!rows) {
        error("markdup_import: no rows selected from ${params.import_sheet}")
    }
    def settings = zgRunSettings()
    def out = [libraries: [], samples: [], imports: [], records: []]
    rows.each { row, path, index ->
        def lib = row.library ?: row.import_set
        def meta = [id: row.id, sample: row.id, library: lib, source: row.source ?: '', role: row.role ?: '',
                    donor: row.donor ?: '', single_end: false, qc_group: row.import_set]
        def read_group = zgReadGroup(row.id, lib, 'ILLUMINA', '')
        def origin = [kind: 'import', path: path.toString(), made_by: row.made_by ?: '', note: row.note ?: '',
                      input_filters: 'as made by zealbc1 / nilhmm (minibwa -x sr, MAPQ 20, -F 0x904)']
        out.imports << [meta, path, index, read_group]
        out.records << [meta.id, zgProvenanceRecord(settings, meta, "${params.store}/cram_import", origin,
                        'from the input header if it has exactly one @RG with SM = sample, else the sample sheet (see <sample>.read_group.txt)')]
    }
    return out
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ZEALGT FUNCTIONS: read groups, provenance, store
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Read group (PLAN §4 #1b): ID = SM = sample, LB = library (BC1 pool / batch-2 row / batch-1 plate), PL = ILLUMINA,
// PU = flowcell.lane(s) when known. Escaped tabs (\t), as minibwa -R and samtools addreplacerg -r take it.
//
def zgReadGroup(String sample, String library, String platform, String pu) {
    def fields = ["ID:${sample}", "SM:${sample}", "LB:${library}", "PL:${platform ?: 'ILLUMINA'}"]
    if (pu) {
        fields << "PU:${pu}"
    }
    return '@RG\\t' + fields.join('\\t')
}

//
// PU from Novogene-style lane file names (<...>_<flowcell>_L<lane>_1.fq.gz): "flowcell.lane[,flowcell.lane...]", or ''.
//
def zgPlatformUnit(List names) {
    def units = names.collect { n ->
        def m = n =~ /_([A-Za-z0-9]+)_L0*(\d+)_[12]\.f(?:ast)?q\.gz$/
        m.find() ? "${m.group(1)}.${m.group(2)}" : null
    }
    return units.contains(null) ? '' : units.unique().join(',')
}

//
// Code version of the checkout: git commit (+ '-dirty' when tracked files differ), or the manifest version.
//
def zgCodeVersion() {
    try {
        def head = "git -C ${projectDir} rev-parse HEAD".execute().text.trim()
        def dirty = "git -C ${projectDir} status --porcelain --untracked-files=no".execute().text.trim()
        return head ? head + (dirty ? '-dirty' : '') : "${workflow.manifest.version}"
    } catch (Exception e) {
        log.warn("zealgt: no git version for ${projectDir}: ${e.message}")
        return "${workflow.manifest.version}"
    }
}

// Run-level settings recorded in every provenance record (PLAN §3 stop point), computed once per run.
def zgRunSettings() {
    return [
        reference    : params.fasta,
        code_version : zgCodeVersion(),
        pipeline     : "${workflow.manifest.name} ${workflow.manifest.version}".toString(),
        entry        : params.entry,
        run_id       : params.run_id ?: '',
        run_name     : workflow.runName,
        session_id   : workflow.sessionId.toString(),
        profile      : workflow.profile,
        mapq_filter  : 'none (applied by the genotype workflow at read time)',
        markdup      : "samtools markdup ${params.markdup_args}".toString(),
    ]
}

// One sample's provenance record: run settings + sample fields + origin (PROVENANCE adds versions.yml files and the CRAM size).
def zgProvenanceRecord(Map settings, Map meta, String store_dir, Map origin, String read_group) {
    return settings + [
        sample     : meta.id,
        library    : meta.library,
        source     : meta.source ?: '',
        role       : meta.role ?: '',
        donor      : meta.donor ?: '',
        store_dir  : store_dir,
        origin     : origin,
        read_group : read_group,
    ]
}

// A sample counts as stored when its CRAM and index are in the store directory (storeDir would skip it anyway).
def zgIsStored(String dir, String id) {
    return file("${dir}/${id}.cram").exists() && file("${dir}/${id}.cram.crai").exists()
}

// A stored CRAM as the QC / provenance steps take it: [ meta, cram, crai, [ <id>.<module>.versions.yml if present ] ]
def zgStoredCram(String dir, Map meta, String module) {
    def versions = file("${dir}/${meta.id}.${module}.versions.yml")
    return [meta, file("${dir}/${meta.id}.cram"), file("${dir}/${meta.id}.cram.crai"), versions.exists() ? [versions] : []]
}

// QC files of a sample already in the store directory: [ id, [ files ] ] (CRAM_QC_PROVENANCE skips what is there)
def zgStoredQc(String dir, String id) {
    return [id, ["${id}.stats", "${id}.CollectWgsMetrics.coverage_metrics", "${id}.markdup.stats"].collect { n -> file("${dir}/${n}") }.findAll { f -> f.exists() }]
}
