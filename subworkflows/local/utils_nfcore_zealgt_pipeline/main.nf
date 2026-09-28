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
    def inputs = [libraries: [], checkpoint: [], imports: [], records: []]
    if (params.workflow == 'cram') {
        inputs = params.entry == 'markdup_import' ? zgImportInputs()
               : params.entry == 'read_alignment' ? zgAlignmentInputs()
               : zgDemuxInputs()
    }

    emit:
    libraries  = channel.fromList(inputs.libraries)  // channel: [ val(lmeta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]  (read_demultiplexing)
    checkpoint = channel.fromList(inputs.checkpoint) // channel: [ val(meta), val(checkpoint row) ]  every sample of the stage-2 libraries (read_demultiplexing, read_alignment)
    imports    = channel.fromList(inputs.imports)    // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]  (markdup_import)
    records    = channel.fromList(inputs.records)    // channel: [ val(sample_id), val(provenance record) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    ch_task_dirs    // channel: [ library, process, task work dir ]  this run's stage-1 tasks holding a library's FASTQs

    main:

    // Checkpoint cleanup report + cleanup commands after every run with stage 2 (read_demultiplexing, read_alignment).
    // onComplete runs after Nextflow has finished the publishDir transfers (26.04.6: Session.destroy shuts the publish pool
    // down first), but params / projectDir are unbound there, so the report gets its values now.
    def cleanup = params.workflow == 'cram' && params.entry in ['read_demultiplexing', 'read_alignment'] ? [
        libraries    : zgList(params.libraries).unique(),
        checkpoint   : zgList(params.libraries).collectEntries { lib -> [lib, zgCheckpointDir(lib).toString()] },
        cram_dir     : "${params.store}/cram".toString(),
        schema       : "${projectDir}/assets/schema_checkpoint.json".toString(),
        script       : file("${params.outdir}/pipeline_info/cleanup_${params.run_id ?: workflow.sessionId}.sh").toAbsolutePath().normalize().toString(),
        entry        : params.entry,
        run_id       : params.run_id ?: '',
        session_id   : workflow.sessionId.toString(),
        run_name     : workflow.runName,
        launch_dir   : workflow.launchDir.toString(),
        work_dir     : workflow.workDir.toString(),
        code_version : zgCodeVersion(),
    ] : null
    // this run's stage-1 task dirs, gathered while the run goes (the channel has ended when onComplete runs)
    def task_dirs = Collections.synchronizedList([])
    ch_task_dirs.subscribe { lib, process, dir -> task_dirs << [lib, process, dir] }

    //
    // Completion summary
    //
    workflow.onComplete {

        completionSummary(monochrome_logs)
        if (cleanup) {
            def reports = zgCheckpointCleanupReport(cleanup)
            zgCleanupCommands(cleanup, reports, task_dirs.toList().unique())
        }

    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs for common issues: https://nf-co.re/docs/running/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS (template): methods description for MultiQC
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Unused since the template's workflows/zealgt.nf was removed (2026-09-28); the CRAM workflow's MultiQC has no methods
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
    return zgSplit(value, ',')
}

def zgSplit(value, String sep) {
    return value ? value.toString().tokenize(sep)*.trim().findAll { v -> v } : []
}

//
// Guards applied before any task runs (the schema already checked types, patterns and integer ranges).
//
def zgRunGuards() {
    def profiles = workflow.profile.tokenize(',')
    if (profiles.intersect(['hazel', 'slurm']) && !params.run_id) {
        error("--run_id is required on hazel: it names the scratch dir /share/maize/frodrig4/nf_work/<run_id> (conf/hazel.config)")
    }
    // a subset never lands where the real CRAMs go (a stored subsample CRAM would make the skip-if-stored logic skip the
    // real alignment), and stub outputs never land in the real store
    zgCheckOutputRoot('--store', params.store, 'store_stub', '/rsstu/users/r/rrellan/BZea/ZEAL/store', '<outdir>/store_stub')
    def stage2 = params.workflow == 'cram' && params.entry in ['read_demultiplexing', 'read_alignment']
    if (stage2) {
        // the same two rules for the FASTQ checkpoint (a subsample checkpoint must never feed a full-library stage 2)
        zgCheckOutputRoot('--fastq_checkpoint', params.fastq_checkpoint, 'checkpoint_stub', '/share/maize/frodrig4/fastq_checkpoint', '<outdir>/checkpoint_stub')
    }
    if (stage2 && !params.libraries) {
        error("--entry ${params.entry} needs --libraries <library>[,<library>...] (meta/samples.csv 'library' column)")
    }
}

//
// Rules for an output root (--store, --fastq_checkpoint): with --subsample N it must be a directory named subsample_<N>, a
// subsample_* directory needs --subsample, and a stub run needs a path component starting with <stub_prefix>, outside the
// production root.
//
def zgCheckOutputRoot(String option, String path, String stub_prefix, String production_path, String stub_default) {
    def root = zgRealPath(path)
    def subsample_dir = zgSubsample() ? "subsample_${zgSubsample()}" : ''
    if (subsample_dir && root.name != subsample_dir) {
        error("--subsample ${zgSubsample()} needs ${option} to be a directory named ${subsample_dir}: ${option} <dir>/${subsample_dir} (got ${root})")
    }
    if (!subsample_dir && root.name ==~ /subsample_\d+/) {
        error("${option} ${root} is a subsample directory; name it with --subsample ${root.name - 'subsample_'} (or use the full one)")
    }
    if (workflow.stubRun) {
        def production = zgRealPath(production_path)
        if (!root.iterator().any { p -> p.toString().startsWith(stub_prefix) } || root.startsWith(production)) {
            error("stub runs must not write into the real ${option - '--'}: ${option} must be (inside) a directory named ${stub_prefix}* outside ${production} (conf/stub.config sets ${stub_default}), got ${root}")
        }
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
// read_demultiplexing request (PLAN §0 Task 2): --force_demux only names requested libraries, and a registered library is
// refused unless it is named with --force_demux, and the libraries whose FASTQs the run holds on disk are bounded
// (zgCheckCheckpointBound, PLAN §5 rule 3).
//
def zgCheckDemuxRequest(List libs) {
    zgCheckCheckpointBound(libs)
    def force = zgList(params.force_demux)
    if (force - libs) {
        error("--force_demux names libraries that are not in --libraries: ${force - libs}")
    }
    def registered = zgRegisteredLibraries()
    def refused = libs.findAll { l -> registered.containsKey(l) && !(l in force) }
    if (refused) {
        error("refusing to demultiplex registered libraries ${refused.collect { l -> "${l} [${registered[l]}]" }} (PLAN §0 Task 2); name them with --force_demux to override")
    }
    // a FASTQ checkpoint written by another session: stage 2 alone reads it; demultiplexing again would replace it
    // (-resume of the session that wrote it is allowed: its cached tasks publish the same files)
    libs.findAll { l -> !(l in force) }.each { l ->
        def sheet = zgCheckpointSheet(l)
        if (sheet.exists()) {
            def sessions = zgCheckpointSessions(sheet)
            if (sessions != [workflow.sessionId.toString()]) {
                error("library ${l} already has a FASTQ checkpoint ${sheet} (stage 1 of session ${sessions ?: 'unknown'}): run stage 2 alone with --entry read_alignment --libraries ${l}; to demultiplex again use -resume <that session> or --force_demux ${l} (replaces the checkpoint)")
            }
        }
    }
    force.each { l -> log.warn("--force_demux ${l}: demultiplexing a registered library (${registered[l] ?: 'not registered'})") }
}

//
// Disk bound (PLAN §5 rule 3): the FASTQs of a library stay in work/ (every library of the run, for the whole run) and in
// its checkpoint dir until the user removes them; nothing is removed automatically. So a read_demultiplexing run is refused
// when the requested libraries plus the libraries already holding a checkpoint dir under --fastq_checkpoint are more than
// --max_libraries. The requested libraries then all run concurrently. subsample_<N> / checkpoint_stub* dirs are other
// checkpoint roots, not libraries.
//
def zgCheckpointLibraries() {
    def root = file(params.fastq_checkpoint).toAbsolutePath().normalize()
    if (!root.isDirectory()) {
        return []
    }
    return root.listFiles()
        .findAll { d -> d.isDirectory() && !(d.name ==~ /\..*|subsample_\d+|checkpoint_stub.*/) }
        .collect { d -> d.name }
        .sort()
}

def zgCheckCheckpointBound(List libs) {
    def held = zgCheckpointLibraries()
    def union = (libs + held).unique()
    if (union.size() > zgMaxLibraries()) {
        def others = held - libs
        def root = file(params.fastq_checkpoint).toAbsolutePath().normalize()
        def status = others.collect { l ->
            def tsv = zgCheckpointDir(l).resolve('cleanup_status.tsv')
            def where = tsv.exists() ? tsv.toString() : "${zgCheckpointDir(l)} (no cleanup_status.tsv yet)"
            "  ${l}: ${where}"
        }
        def msg = "--libraries ${libs.join(',')} and the libraries already holding a FASTQ checkpoint in ${root} are ${union.size()} libraries, more than --max_libraries ${zgMaxLibraries()} (PLAN §5 rule 3: the disk holds the FASTQs of all of them; nothing is removed automatically)."
        if (others) {
            msg += "\nLibraries holding a checkpoint (see each cleanup_status.tsv; remove a checkpoint only with the user's consent, once it says removable):\n${status.join('\n')}"
        }
        error(msg + "\nRequest fewer libraries, clean up finished checkpoints (with consent), or raise --max_libraries if the disk allows it.")
    }
}

// stage1_session_id values of a checkpoint samplesheet ([] if it cannot be read)
def zgCheckpointSessions(sheet) {
    try {
        return zgReadCheckpointSheet(sheet)*.stage1_session_id.unique()
    } catch (Exception e) {
        log.warn("zealgt: cannot read ${sheet}: ${e.message}")
        return []
    }
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
// sample its checkpoint samplesheet row (zgCheckpointRow: everything stage 2 needs, written to
// <fastq_checkpoint>/<library>/samplesheet.csv once the library is trimmed), meta and provenance record, built from that row
// exactly as --entry read_alignment builds them. Origins and read groups stay out of `meta` (meta is hashed).
//
def zgDemuxInputs() {
    def libs = zgList(params.libraries).unique()
    zgCheckDemuxRequest(libs)
    def rows = samplesheetToList(params.input, "${projectDir}/assets/schema_input.json").collect { row -> (row instanceof List ? row[0] : row) as Map }
    def settings = zgRunSettings()
    def registry_file = zgRegistryFile()
    def registry_rows = zgRegistryRows()
    def out = [libraries: [], checkpoint: [], imports: [], records: []]
    libs.each { lib ->
        def lrows = rows.findAll { r -> r.library == lib }
        if (!lrows) {
            error("library ${lib} has no samples in ${params.input}")
        }
        def first = lrows[0]
        // a cross-row rule nf-schema cannot express; meta/build_samples.py checks it too
        ['source', 'barcode_layout', 'raw_location', 'raw_r1', 'raw_r2', 'rg_pu'].findAll { k -> lrows.collect { r -> zgCell(r[k]) }.unique().size() != 1 }.each { k ->
            error("library ${lib}: samples disagree on ${k} in ${params.input}")
        }
        def structures = (first.barcode_layout == 'symmetric' ? params.read_structure_symmetric : params.read_structure_r1_only).tokenize(' ')
        def raw = zgRawFiles(lib, first)
        // PU: the sheet's rg_pu (batch 1: flowcell from the read headers, lanes from the tar members; meta/build_samples.py),
        // else from the Novogene lane file names
        def pu = zgCell(first.rg_pu) ?: zgPlatformUnit(raw.r1*.name)
        def lmeta = [id: lib, library: lib, source: first.source, layout: first.barcode_layout, n_samples: lrows.size(), pu: pu]
        out.libraries << [lmeta, raw.r1, raw.r2, lrows.collect { r -> [r.sample_id, r.barcode_r1, r.barcode_r2 ?: ''] }, structures, [raw.members_r1, raw.members_r2]]
        def ckpt = zgCheckpointDir(lib)
        lrows.each { r ->
            // fastq_1 / fastq_2: where TRIMMOMATIC's publishDir (conf/modules.config) hardlinks the trimmed pair
            def row = zgCheckpointRow([
                sample: r.sample_id, library: lib,
                fastq_1: ckpt.resolve("${r.sample_id}.paired.trim_1.fastq.gz"), fastq_2: ckpt.resolve("${r.sample_id}.paired.trim_2.fastq.gz"),
                source: r.source, role: r.role, donor: r.donor, taxon: r.taxon,
                registry_file: registry_file] + zgRegistryColumnsOf(registry_rows[r.sample_id], r) + [
                read_group: zgReadGroup(r.sample_id, r.rg_lb ?: r.library, r.rg_pl, pu),
                read_structure: structures.join(' '), layout: first.barcode_layout, barcode_r1: r.barcode_r1, barcode_r2: r.barcode_r2,
                demux_args: params.demux_args, trim_illuminaclip: params.trim_illuminaclip, trim_args: params.trim_args,
                trim_adapters: params.trim_adapters, raw_location: raw.location,
                raw_files_r1: raw.r1*.name.join(';'), raw_files_r2: raw.r2*.name.join(';'),
                tar_members_r1: raw.members_r1.join(';'), tar_members_r2: raw.members_r2.join(';'), subsample: zgSubsample(),
                stage1_run_id: params.run_id, stage1_session_id: workflow.sessionId, stage1_code_version: settings.code_version,
                stage1_tool_versions: '', // filled in by the CRAM workflow from this session's DEMUX / TRIMMOMATIC versions
            ])
            zgCsvLine(row) // refuse now, not after trimming, a value the samplesheet cannot hold
            def meta = zgCheckpointMeta(row)
            out.checkpoint << [meta, row]
            out.records << [meta.id, zgCheckpointRecord(settings, row)]
        }
    }
    zgCheckStoredCrams("${params.store}/cram", out.checkpoint.collect { c -> c[0].id })
    return out
}

//
// --entry read_alignment (stage 2 alone): the checkpoint samplesheets <fastq_checkpoint>/<library>/samplesheet.csv of the
// --libraries (assets/schema_checkpoint.json: the FASTQs must exist) -> per sample meta, row and provenance record, built as
// read_demultiplexing builds them. No registry / demux guard (nothing is demultiplexed); REGISTRY needs the library's
// <store>/demux_qc/<library>.tsv and is skipped, with a warning, without it.
//
def zgAlignmentInputs() {
    def libs = zgList(params.libraries).unique()
    def settings = zgRunSettings()
    def out = [libraries: [], checkpoint: [], imports: [], records: []]
    libs.each { lib ->
        def sheet = zgCheckpointSheet(lib)
        if (!sheet.exists()) {
            error("--entry read_alignment: library ${lib} has no checkpoint samplesheet ${sheet}: run --entry read_demultiplexing --libraries ${lib} with this --fastq_checkpoint first")
        }
        def rows = zgReadCheckpointSheet(sheet)
        rows.findAll { row -> row.library != lib }.each { row -> error("${sheet}: sample ${row.sample} is in library ${row.library}, not ${lib}") }
        rows.findAll { row -> row.subsample != zgSubsample() }.each { row ->
            error("${sheet}: sample ${row.sample} was demultiplexed with --subsample ${row.subsample}, this run has --subsample ${zgSubsample()}")
        }
        if (!file("${params.store}/demux_qc/${lib}.tsv").exists()) {
            log.warn("zealgt: ${params.store}/demux_qc/${lib}.tsv is missing (stage 1 ran with another --store?): library ${lib} is aligned but not registered")
        }
        rows.each { row ->
            def meta = zgCheckpointMeta(row)
            out.checkpoint << [meta, row]
            out.records << [meta.id, zgCheckpointRecord(settings, row)]
        }
    }
    zgCheckStoredCrams("${params.store}/cram", out.checkpoint.collect { c -> c[0].id })
    return out
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ZEALGT FUNCTIONS: FASTQ checkpoint (stage 1 -> stage 2)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    <fastq_checkpoint>/<library>/: the trimmed pairs <sample>.paired.trim_{1,2}.fastq.gz (hardlinks of TRIMMOMATIC's work/
    outputs), samplesheet.csv (assets/schema_checkpoint.json; one row per sample, everything stage 2 needs) and, after
    every run with stage 2, cleanup_status.tsv (zgCheckpointCleanupReport). Nothing here removes a file.
*/

// Checkpoint samplesheet columns, in file order (assets/schema_checkpoint.json): the stage-2 fields, then the registry
// snapshot (registry_file, registry_note and reg_<column> for every zgRegistryFields / zgRegistryResolvedFields column), then
// the stage-1 settings
def zgCheckpointColumns() {
    return ['sample', 'library', 'fastq_1', 'fastq_2', 'source', 'role', 'donor', 'taxon', 'registry_file', 'registry_note'] +
           (zgRegistryFields() + zgRegistryResolvedFields()).collect { f -> "reg_${f}".toString() } +
           ['read_group', 'read_structure', 'layout',
            'barcode_r1', 'barcode_r2', 'demux_args', 'trim_illuminaclip', 'trim_args', 'trim_adapters', 'raw_location',
            'raw_files_r1', 'raw_files_r2', 'tar_members_r1', 'tar_members_r2', 'subsample', 'stage1_run_id', 'stage1_session_id',
            'stage1_code_version', 'stage1_tool_versions']
}

def zgCheckpointDir(String lib) {
    return file(params.fastq_checkpoint).toAbsolutePath().normalize().resolve(lib)
}

def zgCheckpointSheet(String lib) {
    return zgCheckpointDir(lib).resolve('samplesheet.csv')
}

// A samplesheet cell as a string: nf-schema hands an empty cell over as [], a file-path cell as a Path
def zgCell(value) {
    return (value == null || (value instanceof List && !value)) ? '' : value.toString()
}

// One checkpoint row with every column, strings except the integer subsample (the same types whether built or read back)
def zgCheckpointRow(Map m) {
    return zgCheckpointColumns().collectEntries { c -> [c, c == 'subsample' ? zgCell(m[c] ?: 0).toInteger() : zgCell(m[c])] }
}

// The rows of a checkpoint samplesheet: validated by nf-schema (FASTQs must exist), values read as the text stage 1 wrote
// (nf-schema infers types of untyped cells, e.g. FALSE -> false, 1 -> 1; the registry snapshot keeps the registry's spelling)
def zgReadCheckpointSheet(sheet) {
    def n = samplesheetToList(sheet.toString(), "${projectDir}/assets/schema_checkpoint.json").size()
    def rows = zgReadCsv(sheet)
    if (rows.size() != n) {
        error("${sheet}: ${rows.size()} rows read as text, ${n} validated")
    }
    return rows.collect { r -> zgCheckpointRow(r) }
}

//
// A CSV file as a list of maps (header -> cell), all strings. Cells may be "..."-quoted (commas inside; "" = one quote),
// no newline inside a cell; \r\n or \n line ends. Used for meta/registry.csv (--registry) and the checkpoint samplesheet.
//
def zgReadCsv(path) {
    def lines = file(path.toString()).text.split(/\r?\n/).findAll { l -> l }
    if (!lines) {
        return []
    }
    def header = zgCsvSplit(lines[0], path)
    return lines.drop(1).withIndex().collect { l, i ->
        def cells = zgCsvSplit(l, path)
        if (cells.size() != header.size()) {
            error("${path}: line ${i + 2} has ${cells.size()} cells, the header ${header.size()}")
        }
        [header, cells].transpose().collectEntries { h, c -> [h, c] }
    }
}

def zgCsvSplit(String line, path) {
    def cells = []
    def cur = new StringBuilder()
    def quoted = false
    def skip = false
    def chars = line.toList()
    chars.eachWithIndex { ch, i ->
        if (skip) {
            skip = false
        } else if (quoted && ch == '"' && i + 1 < chars.size() && chars[i + 1] == '"') {
            cur.append('"')
            skip = true
        } else if (ch == '"') {
            quoted = !quoted
        } else if (ch == ',' && !quoted) {
            cells << cur.toString()
            cur.setLength(0)
        } else {
            cur.append(ch)
        }
    }
    if (quoted) {
        error("${path}: unbalanced quote in line: ${line}")
    }
    cells << cur.toString()
    return cells
}

// One CSV line; nf-schema reads "..."-quoted cells (commas inside) but not escaped quotes, so a quote or newline is refused
def zgCsvLine(Map row) {
    return zgCheckpointColumns().collect { c ->
        def s = zgCell(row[c])
        if (s.contains('"') || s.contains('\n') || s.contains('\r')) {
            error("checkpoint samplesheet: ${c} of sample ${row.sample} contains a quote or newline, which the samplesheet cannot hold: ${s}")
        }
        s.contains(',') ? "\"${s}\"" : s
    }.join(',')
}

//
// Write <fastq_checkpoint>/<library>/samplesheet.csv for the rows of one library (all its samples trimmed), via a temporary
// file and an atomic move, so a killed run never leaves half a samplesheet.
//
def zgWriteCheckpointSheet(List rows) {
    def sheet = file(rows[0].fastq_1).parent.resolve('samplesheet.csv')
    def tmp = sheet.parent.resolve('.samplesheet.csv.tmp')
    sheet.parent.mkdirs()
    tmp.text = ([zgCheckpointColumns().join(',')] + rows.sort(false) { r -> r.sample }.collect { r -> zgCsvLine(r) }).join('\n') + '\n'
    java.nio.file.Files.move(tmp, sheet, java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
    log.info("zealgt: FASTQ checkpoint samplesheet ${sheet} (${rows.size()} samples)")
    return sheet
}

// Stage-2 meta of a checkpoint row (the same fields for both stage-2 entries; meta is hashed)
def zgCheckpointMeta(Map row) {
    return [id: row.sample, sample: row.sample, library: row.library, source: row.source, role: row.role, donor: row.donor,
            taxon: row.taxon, single_end: false, qc_group: row.library]
}

//
// Provenance record of a checkpoint row (origin = demux), shared by both stage-2 entries, so the JSON differs only in the
// run fields. stage1_tool_versions: the DEMUX / TRIMMOMATIC tool versions of the session that wrote the checkpoint.
//
def zgCheckpointRecord(Map settings, Map row) {
    def meta = zgCheckpointMeta(row)
    def origin = [kind: 'demux', library: row.library, raw_location: row.raw_location,
                  raw_files_r1: zgSplit(row.raw_files_r1, ';'), raw_files_r2: zgSplit(row.raw_files_r2, ';'),
                  tar_members_r1: zgSplit(row.tar_members_r1, ';'), tar_members_r2: zgSplit(row.tar_members_r2, ';'),
                  tool: 'cutadapt', args: row.demux_args, read_structure: row.read_structure, layout: row.layout,
                  barcode_r1: row.barcode_r1, barcode_r2: row.barcode_r2, subsample: row.subsample,
                  fastq_checkpoint: [row.fastq_1, row.fastq_2], stage1_run_id: row.stage1_run_id,
                  stage1_session_id: row.stage1_session_id, stage1_code_version: row.stage1_code_version,
                  stage1_tool_versions: zgParseToolVersions(row.stage1_tool_versions)]
    def reg = row.registry_note ? null : (zgRegistryFields() + zgRegistryResolvedFields()).collectEntries { f -> [f, row["reg_${f}".toString()]] }
    def registry = zgRegistrySnapshot(row.registry_file, row.stage1_code_version, reg)
    return zgProvenanceRecord(settings, meta, "${params.store}/cram", origin, row.read_group, registry) + [
        // phred: -phred33, TRIMMOMATIC ext.args3 (conf/modules.config; the zealgt patch puts it before the inputs)
        trimming : [tool: 'trimmomatic', illuminaclip: row.trim_illuminaclip, args: row.trim_args,
                    adapters: row.trim_adapters, phred: 'phred33'],
        alignment: [tool: 'minibwa map', args: params.align_args, read_group: row.read_group],
    ]
}

// The tools that make the checkpoint FASTQs, i.e. the version outputs of DEMUX (cutadapt, pigz, tar) and TRIMMOMATIC. The CRAM
// workflow waits until each has reported once: a tool added to those modules must be added here (else the samplesheet and
// the provenance records wait for the end of stage 1).
def zgStage1Tools() {
    return ['cutadapt', 'pigz', 'tar', 'trimmomatic']
}

// [[tool, version], ...] -> "tool=version;tool=version" (sorted; several versions of one tool comma-joined)
def zgToolVersionsString(List tools) {
    return tools.groupBy { t -> t[0] }.collect { tool, vs -> "${tool}=${vs*.getAt(1).unique().sort().join(',')}" }.sort().join(';')
}

def zgParseToolVersions(String s) {
    return zgSplit(s, ';').collectEntries { tv -> def i = tv.indexOf('='); [tv.substring(0, i), tv.substring(i + 1)] }
}

// A chained run's record once this session's stage-1 tool versions are known (as read_alignment reads them from the sheet)
def zgWithStage1Tools(Map record, String tools) {
    return record + [origin: record.origin + [stage1_tool_versions: zgParseToolVersions(tools)]]
}

//
// Checkpoint cleanup report (never removes anything), from workflow.onComplete after every run with stage 2: per library,
// are ALL its samples' CRAMs stored and verified (zgCramState)? Writes <checkpoint>/<library>/cleanup_status.tsv and logs
// "removable" or "keep". Called from onComplete, where params / projectDir are no longer bound: everything comes in `ctx`
// [libraries, checkpoint dirs by library, cram dir, schema path]. Returns one map per library for zgCleanupCommands:
// [library, dir, removable, status, rows].
//
def zgCheckpointCleanupReport(Map ctx) {
    return ctx.libraries.collect { lib ->
        def dir = file(ctx.checkpoint[lib])
        def sheet = dir.resolve('samplesheet.csv')
        if (!sheet.exists()) {
            def status = "checkpoint ${dir}: keep: no samplesheet.csv (stage 1 of library ${lib} did not finish)"
            log.warn("zealgt: ${status}")
            return [library: lib, dir: dir.toString(), removable: false, status: status, rows: []]
        }
        def rows
        try {
            rows = samplesheetToList(sheet.toString(), ctx.schema).collect { r -> r[0] + [fastq_1: r[1], fastq_2: r[2]] }
        } catch (Exception e) {
            def status = "checkpoint ${dir}: keep: ${sheet} does not validate (${e.message})"
            log.warn("zealgt: ${status}")
            return [library: lib, dir: dir.toString(), removable: false, status: status, rows: []]
        }
        def lines = [['sample', 'cram', 'cram_bytes', 'verified', 'fastq_1', 'fastq_1_bytes', 'fastq_2', 'fastq_2_bytes'].join('\t')]
        def n_ok = 0
        def bytes = 0L
        rows.each { r ->
            def id = zgCell(r.sample)
            def cram = file("${ctx.cram_dir}/${id}.cram")
            def ok = zgCramState(ctx.cram_dir, id) == 'stored'
            n_ok += ok ? 1 : 0
            def fq = [file(zgCell(r.fastq_1)), file(zgCell(r.fastq_2))]
            bytes += fq.sum { f -> f.size() }
            lines << [id, cram, cram.exists() ? cram.size() : 0, ok ? 'yes' : 'no', fq[0].name, fq[0].size(), fq[1].name, fq[1].size()].join('\t')
        }
        def status = n_ok == rows.size()
            ? "checkpoint ${dir}: removable (${2 * rows.size()} files, ${String.format('%.2f', bytes / 1e9)} GB) — remove only with the user's consent"
            : "checkpoint ${dir}: keep: ${rows.size() - n_ok} of ${rows.size()} CRAMs missing"
        dir.resolve('cleanup_status.tsv').text = (lines + ["# ${status}"]).join('\n') + '\n'
        log.info("zealgt: ${status} (${dir}/cleanup_status.tsv)")
        return [library: lib, dir: dir.toString(), removable: n_ok == rows.size(), status: status, rows: rows]
    }
}

//
// End-of-run cleanup commands, NEVER run by the pipeline: written to <outdir>/pipeline_info/cleanup_<run_id or session>.sh
// and printed in the log, for the user to read, check and (with consent) use. Per library of the run (zgCheckpointCleanupReport):
//   removable (every CRAM stored and verified) -> listing / measuring commands (ls, du, find -maxdepth | wc -l, cat) for its
//     checkpoint dir and for this run's work dirs of its DEMUX, MERGE_LANES, TRIMMOMATIC and FASTQC tasks, then the removal
//     lines, commented out and marked "CONSENT:";
//   otherwise -> its "keep: ..." status and no removal line.
// The task dirs come from those processes' output channels (workflows/cram.nf, `task_dirs`: each output file's
// <workDir>/xx/hash dir), so they are exactly the tasks whose outputs this run used, cached ones included (their outputs
// point to the earlier task dir); failed / retried attempts never reach a channel and are left to `nextflow clean`. Chosen
// over parsing the trace file: the trace has no library and only the hash prefix, and it is still being written when
// onComplete runs. Sizes and file counts are measured here (zgDirStats, depth-bounded, symlinks not followed). A
// `nextflow clean` alternative for the whole run is offered when every library of the run is removable.
//
def zgCleanupCommands(Map ctx, List reports, List task_dirs) {
    def order = ['DEMUX', 'MERGE_LANES', 'TRIMMOMATIC', 'FASTQC']
    def out = [
        '#!/usr/bin/env bash',
        '#',
        '# zealgt cleanup commands. NEVER RUN BY THE PIPELINE: the pipeline only writes this file. READ ALL OF IT BEFORE USING ANY LINE.',
        '#',
        "# Written at the end of run ${ctx.run_name} (session ${ctx.session_id}, run_id ${ctx.run_id ?: '-'}, entry ${ctx.entry}, code ${ctx.code_version}), ${java.time.Instant.now()}.",
        "# Launch dir ${ctx.launch_dir}; work dir ${ctx.work_dir}; CRAM store ${ctx.cram_dir}.",
        '#',
        '# The active lines only list and measure (ls, du, find -maxdepth ... | wc -l, cat): running this file as it is removes nothing.',
        '# Every removal line is commented out and marked "CONSENT:". Uncomment or copy one only after the user has explicitly',
        '# approved that removal (CLAUDE.md; docs/PLAN_pipeline.md §5 rule 4), and only after the listing shows the paths are still',
        '# what this file says (sizes and file counts below were measured by the pipeline at the end of the run).',
        '# A library is removable only when every one of its CRAMs is stored and verified (CRAM + .crai + CRAM 3 EOF), as its',
        '# <checkpoint>/<library>/cleanup_status.tsv says. The checkpoint FASTQs are hardlinks of TRIMMOMATIC work/ files: their space',
        '# is freed only when both the checkpoint dir and the TRIMMOMATIC task dirs are gone. Afterwards the CRAMs stay in the store',
        '# (skipped as stored); --entry read_alignment can no longer read that checkpoint, a -resume of this session redoes stage 1,',
        '# and the removed checkpoint dir no longer counts against --max_libraries.',
        '# Listed task dirs are the tasks whose outputs this run used (cached ones included); failed or retried attempts are not',
        "# listed: in the launch dir, `nextflow log ${ctx.run_name} -f name,status,workdir` lists every task dir of the run.",
    ]
    reports.each { rep ->
        out << '#'
        if (!rep.removable) {
            out << "# ==== library ${rep.library}: ${rep.status - "checkpoint ${rep.dir}: "}; no removal line ===="
            out << "# checkpoint ${rep.dir}" + (rep.rows ? " (see its cleanup_status.tsv)" : '')
            return
        }
        def ck = zgDirStats(rep.dir, 1)
        out << "# ==== library ${rep.library}: removable: all ${rep.rows.size()} CRAMs stored and verified ===="
        out << "# checkpoint ${rep.dir}: " + (ck ? zgStatsText(ck) : 'not found')
        out << "ls -la -- ${zgShellQuote(rep.dir)}"
        out << "du -sh -- ${zgShellQuote(rep.dir)}"
        out << "find ${zgShellQuote(rep.dir)} -maxdepth 1 ! -type d | wc -l"
        out << "cat -- ${zgShellQuote(rep.dir + '/cleanup_status.tsv')}"
        def dirs = task_dirs.findAll { lib, _p, _d -> lib == rep.library }
            .collect { _lib, p, d -> [p, d, zgDirStats(d, 3)] }
            .findAll { _p, _d, st -> st }
            .sort { a, b -> order.indexOf(a[0]) <=> order.indexOf(b[0]) ?: a[1] <=> b[1] }
        if (dirs) {
            def total = [0, 1, 2].collect { i -> dirs.sum { _p, _d, st -> st[i] } }
            def per = order.collect { p -> [p, dirs.count { dp, _d, _st -> dp == p }] }.findAll { _p, n -> n }.collect { p, n -> "${p} ${n}" }
            out << "# work/ task dirs of this run holding ${rep.library}'s FASTQs: ${dirs.size()} dirs (${per.join(', ')}), ${zgStatsText(total)}"
            dirs.each { p, d, st -> out << "#   ${p.padRight(11)} ${d}  ${zgStatsText(st)}" }
            out << 'work_dirs=('
            dirs.each { _p, d, _st -> out << "    ${zgShellQuote(d)}" }
            out << ')'
            out << 'du -shc -- "${work_dirs[@]}"'
            out << 'find "${work_dirs[@]}" -maxdepth 3 ! -type d | wc -l'
        }
        else {
            def r = rep.rows[0]
            out << "# work/: this run used no stage-1 task of ${rep.library} (entry ${ctx.entry}). Stage 1 ran in session ${zgCell(r.stage1_session_id)}" +
                   " (run_id ${zgCell(r.stage1_run_id) ?: '-'}): its task dirs, if still there, are in that run's own cleanup_<run_id or session>.sh."
        }
        out << "# CONSENT: the lines below remove ${rep.library}'s FASTQs; uncomment them only with the user's explicit approval."
        dirs.each { _p, d, _st -> out << "# rm -r -- ${zgShellQuote(d)}" }
        out << "# rm -r -- ${zgShellQuote(rep.dir)}"
    }
    out << '#'
    out << '# ==== alternative for the whole run: nextflow clean ===='
    def keep = reports.findAll { rep -> !rep.removable }*.library
    if (reports && !keep) {
        out += [
            "# Every library of this run is removable, so instead of the per-library work/ lines above every task dir of run",
            "# ${ctx.run_name} may go at once (stage 1 and stage 2, all libraries; `nextflow clean -n` shows exactly which). It never",
            '# touches the checkpoint (use the per-library lines above for it). Run in the launch dir; on hazel as a short-QOS job',
            '# (hazel-debug-loop skill). Dry run first, it lists and removes nothing:',
            "#   cd ${zgShellQuote(ctx.launch_dir)}",
            "#   nextflow clean -n ${ctx.run_name}",
            "# CONSENT: nextflow clean -f ${ctx.run_name}",
        ]
    }
    else {
        out << "# not offered: ${keep ? "library ${keep.join(', ')} is not removable" : 'no library in this run'}, and nextflow clean removes every task dir of the run."
    }
    def text = out.join('\n') + '\n'
    def script = file(ctx.script)
    script.parent.mkdirs()
    script.text = text
    log.info("zealgt: cleanup commands (never run by the pipeline; read the file before using any line): ${script}\n${text}")
    return script
}

// The task dir (<workDir>/xx/<rest of hash>) holding a task output file, as a string; null for a file outside workDir
def zgTaskDir(f, wd) {
    def p = java.nio.file.Paths.get(f.toString()).toAbsolutePath().normalize()
    def w = java.nio.file.Paths.get(wd.toString()).toAbsolutePath().normalize()
    if (!p.startsWith(w)) {
        return null
    }
    def rel = w.relativize(p)
    return rel.nameCount >= 3 ? w.resolve(rel.getName(0)).resolve(rel.getName(1)).toString() : null
}

//
// [files, bytes, hardlinked bytes] of a directory, at most `depth` levels down, symlinks not followed (null if it is not a
// directory). files = every non-directory entry (regular files and symlinks: each takes an inode of the quota); bytes =
// regular files; hardlinked bytes = regular files with more than one link (freed only once every link is removed).
//
def zgDirStats(String path, int depth) {
    def root = java.nio.file.Paths.get(path)
    def nofollow = java.nio.file.LinkOption.NOFOLLOW_LINKS
    if (!java.nio.file.Files.isDirectory(root, nofollow)) {
        return null
    }
    def n = 0L
    def bytes = 0L
    def linked = 0L
    java.nio.file.Files.walk(root, depth).withCloseable { s ->
        s.iterator().each { p ->
            def a = java.nio.file.Files.readAttributes(p, java.nio.file.attribute.BasicFileAttributes, nofollow)
            if (a.isDirectory()) {
                return
            }
            n += 1
            if (a.isRegularFile()) {
                bytes += a.size()
                def links = 1
                try {
                    links = java.nio.file.Files.getAttribute(p, 'unix:nlink', nofollow) as int
                } catch (Exception _e) {
                    links = 1
                }
                linked += links > 1 ? a.size() : 0
            }
        }
    }
    return [n, bytes, linked]
}

def zgStatsText(List st) {
    return "${st[0]} files, ${zgSize(st[1])}" + (st[2] ? " (${zgSize(st[2])} hardlinked)" : '')
}

def zgSize(long bytes) {
    return bytes >= 1e9 ? String.format('%.2f GB', bytes / 1e9) : bytes >= 1e6 ? String.format('%.1f MB', bytes / 1e6) : String.format('%.1f kB', bytes / 1e3)
}

// A string as one single-quoted shell word
def zgShellQuote(String s) {
    return "'" + s.replace("'", "'\\''") + "'"
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
    def registry_file = zgRegistryFile()
    def registry_rows = zgRegistryRows()
    def out = [libraries: [], checkpoint: [], imports: [], records: []]
    rows.each { row, path, index ->
        def lib = row.library ?: row.import_set
        def meta = [id: row.id, sample: row.id, library: lib, source: row.source ?: '', role: row.role ?: '',
                    donor: row.donor ?: '', single_end: false, qc_group: row.import_set]
        def read_group = zgReadGroup(row.id, lib, 'ILLUMINA', '')
        def origin = [kind: 'import', path: path.toString(), made_by: row.made_by ?: '', note: row.note ?: '',
                      input_filters: 'as made by zealbc1 / nilhmm (minibwa -x sr, MAPQ 20, -F 0x904)',
                      import_sheet_row: zgImportRowSnapshot(row, path, index)]
        // registry snapshot from the registry row of the same sample_id (null, with a note, for a sample not in the registry,
        // e.g. the SRA B73 controls); the import sheet's own row is in origin.import_sheet_row
        def registry = zgRegistrySnapshot(registry_file, settings.code_version, registry_rows[row.id])
        out.imports << [meta, path, index, read_group]
        out.records << [meta.id, zgProvenanceRecord(settings, meta, "${params.store}/cram_import", origin,
                        'from the input header if it has exactly one @RG with SM = sample, else the sample sheet (see <sample>.read_group.txt)', registry)]
    }
    zgCheckStoredCrams("${params.store}/cram_import", out.imports.collect { i -> i[0].id })
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

// Run-level settings recorded in every provenance record (PLAN §3 stop point), computed once per run. The record is a
// PROVENANCE input (hashed), so it holds nothing that changes between launches of one session: no workflow.runName (a
// -resume would rerun every PROVENANCE task; session_id + run_id + code_version identify the run).
def zgRunSettings() {
    return [
        reference    : params.fasta,
        code_version : zgCodeVersion(),
        pipeline     : "${workflow.manifest.name} ${workflow.manifest.version}".toString(),
        entry        : params.entry,
        run_id       : params.run_id ?: '',
        session_id   : workflow.sessionId.toString(),
        profile      : workflow.profile,
        mapq_filter  : 'none (applied by the genotype workflow at read time)',
        markdup      : "samtools markdup ${params.markdup_args}".toString(),
    ]
}

// One sample's provenance record: run settings + sample fields + registry snapshot + origin (PROVENANCE adds versions.yml
// files and the CRAM size).
def zgProvenanceRecord(Map settings, Map meta, String store_dir, Map origin, String read_group, Map registry) {
    return settings + [
        sample     : meta.id,
        library    : meta.library,
        source     : meta.source ?: '',
        role       : meta.role ?: '',
        donor      : meta.donor ?: '',
        registry   : registry,
        store_dir  : store_dir,
        origin     : origin,
        read_group : read_group,
    ]
}

//
// Registry snapshot (meta/PROVENANCE.md "Identifiers"): the sample's row of the sample-identity registry (--registry,
// meta/registry.csv), with the registry file and the code version (git commit) it was read at; a later registry change
// shows as a difference from the current row.
//   row      = the raw identity and biology columns (zgRegistryFields), as the sources give them (text, the registry's spelling)
//   resolved = the *_resolved columns and correction_ids (meta/corrections.csv applied), recorded separately: they never
//              replace a raw value
// The technical columns (raw files, barcodes, library_index, rg_*) are in origin / read_group. Line and nil ids go only here,
// never into a CRAM header. The chained run reads the row from --registry; --entry read_alignment from the checkpoint
// samplesheet (reg_<column>, written by stage 1 from the same row), so both records hold the same snapshot; nothing in it
// changes between launches (the record is a hashed PROVENANCE input).
//
def zgRegistryFields() {
    return ['sample_id', 'source', 'role', 'library', 'plate', 'well', 'lab_seq_id', 'delivered_name', 'accession', 'taxa_code',
            'taxon', 'donor', 'line_id', 'old_line_id', 'pedigree', 'nil_id', 'nil_id_in_register', 'is_check',
            'gen', 'F1', 'BC1', 'BC2', 'S1', 'S2', 'S3', 'S4', 'blk', 'TC', 'j2teo_batch', 'j2teo_seed_origin',
            'field', 'field_plot', 'seed_packet', 'mother_plant', 'replicate_of', 'exclude', 'exclude_reason', 'flags']
}

def zgRegistryResolvedFields() {
    return ['pedigree_resolved', 'nil_id_resolved', 'donor_resolved', 'correction_ids']
}

// --registry as recorded: relative to the pipeline directory when inside it (meta/registry.csv: code_version pins its content)
def zgRegistryFile() {
    def p = file(params.registry).toAbsolutePath().normalize()
    def root = projectDir.toAbsolutePath().normalize()
    return p.startsWith(root) ? root.relativize(p).toString() : p.toString()
}

// The registry rows by sample_id, as text (every snapshot column must be in the header)
def zgRegistryRows() {
    def rows = zgReadCsv(file(params.registry, checkIfExists: true))
    def missing = rows ? (zgRegistryFields() + zgRegistryResolvedFields()) - rows[0].keySet() : []
    if (missing) {
        error("--registry ${params.registry} lacks the columns ${missing} (meta/build_samples.py writes them)")
    }
    def ids = rows*.sample_id
    if (ids.unique(false).size() != ids.size()) {
        error("--registry ${params.registry}: sample_id is not unique")
    }
    return rows.collectEntries { r -> [r.sample_id, r] }
}

//
// The checkpoint's registry columns of one sample (read_demultiplexing): reg_<column> from its registry row. The row must
// agree with the --input row on source and library (a registry that does not belong to the sample sheet is refused); a
// sample without a registry row gets empty columns and registry_note.
//
def zgRegistryColumnsOf(Map reg, Map input_row) {
    if (reg != null && (reg.source != input_row.source || reg.library != input_row.library)) {
        error("sample ${input_row.sample_id}: --registry ${params.registry} says source ${reg.source} / library ${reg.library}, --input ${params.input} says ${input_row.source} / ${input_row.library}")
    }
    return [registry_note: reg == null ? 'sample_id not in the registry' : ''] +
           (zgRegistryFields() + zgRegistryResolvedFields()).collectEntries { f -> ["reg_${f}".toString(), reg == null ? '' : reg[f]] }
}

def zgRegistrySnapshot(String registry_file, String code_version, Map row) {
    return [file    : registry_file, code_version: code_version,
            row     : row == null ? null : zgRegistryFields().collectEntries { f -> [f, zgCell(row[f])] },
            resolved: row == null ? null : zgRegistryResolvedFields().collectEntries { f -> [f, zgCell(row[f])] },
            note    : row == null ? 'sample_id not in the registry' : '']
}

// The import sheet's row as recorded (markdup_import), strings, path and index as given
def zgImportRowSnapshot(Map row, path, index) {
    return ['sample_id', 'source', 'role', 'library', 'donor', 'import_set', 'size_bytes', 'made_by', 'dup_marked', 'read_groups',
            'include', 'note'].collectEntries { f -> [f, zgCell(row[[sample_id: 'id', read_groups: 'read_groups_sheet'][f] ?: f])] } + [path: path.toString(), index: index.toString()]
}

//
// Store (params.store): every output is published there (publishDir mode copy, overwrite false; conf/modules.config) and
// the workflow skips work whose stored output exists (no storeDir). A sample's CRAM counts as stored only when the CRAM
// and its .crai exist and the CRAM ends with the CRAM 3 EOF container, so a copy cut short by a killed head job is caught.
//

// htslib's CRAM 3.x EOF container (cram_io.c), the last 38 bytes of every complete CRAM 3.0 / 3.1 file
def zgCramEof() {
    return '0f000000ffffffff0fe0454f4600000000010005bdd94f0001000606010001000100ee63014b'.decodeHex()
}

def zgCramEofOk(cram) {
    def eof = zgCramEof()
    def size = cram.size()
    if (size < eof.length) {
        return false
    }
    return cram.withInputStream { s -> s.skipNBytes(size - eof.length); java.util.Arrays.equals(s.readNBytes(eof.length), eof) }
}

// The files a sample leaves in a store CRAM directory (<store>/cram or <store>/cram_import)
def zgSampleStoreFiles(String dir, String id) {
    return ['.cram', '.cram.crai', '.markdup.stats', '.align_markdup.versions.yml', '.markdup_import.versions.yml', '.read_group.txt',
            '.stats', '.CollectWgsMetrics.coverage_metrics', '.provenance.json', '.provenance.versions.yml'].collect { s -> file("${dir}/${id}${s}") }
}

//
// 'stored': CRAM + .crai present and the CRAM ends with the EOF container; 'absent': none of the sample's files present;
// 'broken': anything else (an unverified CRAM, or files left over without a CRAM). publishDir never overwrites a stored
// file, so a broken sample is an error for the user to resolve, never silently redone.
//
def zgCramState(String dir, String id) {
    def cram = file("${dir}/${id}.cram")
    def crai = file("${dir}/${id}.cram.crai")
    if (cram.exists() && crai.exists() && zgCramEofOk(cram)) {
        return 'stored'
    }
    return zgSampleStoreFiles(dir, id).any { f -> f.exists() } ? 'broken' : 'absent'
}

def zgIsStored(String dir, String id) {
    return zgCramState(dir, id) == 'stored'
}

// Before any task: refuse the run if a sample of it is broken in the store, naming the files to check and remove
def zgCheckStoredCrams(String dir, List ids) {
    def broken = ids.findAll { id -> zgCramState(dir, id) == 'broken' }
    if (broken) {
        def files = broken.collectMany { id -> zgSampleStoreFiles(dir, id).findAll { f -> f.exists() } }
        error("stored sample(s) ${broken} in ${dir} are incomplete: a CRAM counts as stored only with its .crai and the CRAM 3 EOF block at its end (a copy cut short by a killed run?), and without a CRAM no other file of the sample may be there. zealgt never overwrites a stored file: check and remove these files yourself, then rerun:\n  ${files.join('\n  ')}")
    }
}

// A stored CRAM as the QC / provenance steps take it: [ meta, cram, crai, [ <id>.<module>.versions.yml if present ] ]
def zgStoredCram(String dir, Map meta, String module) {
    def versions = file("${dir}/${meta.id}.${module}.versions.yml")
    return [meta, file("${dir}/${meta.id}.cram"), file("${dir}/${meta.id}.cram.crai"), versions.exists() ? [versions] : []]
}

// QC files and provenance record of a sample already in the store directory: [ id, [ files ] ] (CRAM_QC_PROVENANCE skips
// what is there)
def zgStoredQc(String dir, String id) {
    return [id, ["${id}.stats", "${id}.CollectWgsMetrics.coverage_metrics", "${id}.markdup.stats", "${id}.provenance.json"].collect { n -> file("${dir}/${n}") }.findAll { f -> f.exists() }]
}

// Demux QC of a library already in <store>/demux_qc: [ library, [ tsv, summary.tsv if present ] ], [] when its tsv is not
// there (READ_DEMULTIPLEXING then runs DEMUX_QC)
def zgStoredDemuxQc(String store, String lib) {
    def tsv = file("${store}/demux_qc/${lib}.tsv")
    def summary = file("${store}/demux_qc/${lib}.summary.tsv")
    return [lib, tsv.exists() ? [tsv] + (summary.exists() ? [summary] : []) : []]
}

// A library whose registry entry is already in <store>/registry (REGISTRY is not run again)
def zgIsRegistered(String store, String lib) {
    return file("${store}/registry/${lib}.registry.tsv").exists()
}
