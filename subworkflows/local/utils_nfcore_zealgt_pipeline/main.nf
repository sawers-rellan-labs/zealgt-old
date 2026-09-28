//
// Subworkflow with functionality specific to the sawers-rellan-labs/zealgt pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { paramsHelp                } from 'plugin/nf-schema'
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

    ch_versions = channel.empty()

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
    // Validate parameters and generate parameter summary to stdout
    //

    def before_text = ""
    def after_text = ""
    if (monochrome_logs) {
        before_text = before_text.replaceAll(/\033\[[0-9;]*m/, '')
    }

    command = "nextflow run ${workflow.manifest.name} -profile hazel,short --workflow cram --entry read_demultiplexing --libraries <LIB> --run_id <RUN> --outdir <OUTDIR>"

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
    // zealgt run guards (conf/hazel.config, PLAN §2 / §5)
    //
    zgRunGuards()

    emit:
    versions    = ch_versions
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
    // Completion email and summary
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
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "FastQC (Andrews 2010),",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Andrews S, (2010) FastQC, URL: https://www.bioinformatics.babraham.ac.uk/projects/fastqc/).</li>",
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
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
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ZEALGT FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Store root: params.store, or <store>/subsample_<N> for --subsample runs, so a Gate 1 subset never lands where the real
// CRAMs go (a stored subsample CRAM would make storeDir skip the real alignment). conf/modules.config repeats this rule
// in its storeDir closures.
//
def zgStoreRoot() {
    return zgSubsample() ? "${params.store}/subsample_${zgSubsample()}" : "${params.store}"
}

//
// Integer params (Nextflow 26 hands CLI values over as strings; a string '0' would be truthy)
//
def zgSubsample() {
    return params.subsample.toString().toInteger()
}

def zgMaxLibraries() {
    return params.max_libraries.toString().toInteger()
}

//
// Guards applied before any task runs.
//
def zgRunGuards() {
    def profiles = workflow.profile.tokenize(',')
    if (profiles.intersect(['hazel', 'slurm']) && !params.run_id) {
        error("--run_id is required on hazel: it names the scratch dir /share/maize/frodrig4/nf_work/<run_id> (conf/hazel.config)")
    }
    if (!(params.subsample.toString() ==~ /\d+/) || !(params.max_libraries.toString() ==~ /[1-9]\d*/)) {
        error("--subsample must be an integer >= 0 and --max_libraries an integer >= 1")
    }
    if (zgSubsample() < 0) {
        error("--subsample must be >= 0 (read pairs; 0 = the whole library)")
    }
    if (workflow.stubRun) {
        // the stub store must be its own directory named store_stub* and must not lie inside the production store
        def stub_store = zgRealPath(params.store)
        def production = zgRealPath('/rsstu/users/r/rrellan/BZea/ZEAL/store')
        if (!stub_store.name.startsWith('store_stub') || stub_store.startsWith(production)) {
            error("stub runs must not write into the real store: --store must be a directory named store_stub* outside ${production} (conf/stub.config sets <outdir>/store_stub), got ${stub_store}")
        }
    }
    if (params.workflow == 'cram' && params.entry == 'read_demultiplexing' && !params.libraries) {
        error("--entry read_demultiplexing needs --libraries <library>[,<library>...] (meta/samples.csv 'library' column)")
    }
    if (params.workflow == 'cram' && params.entry in ['read_trimming', 'read_alignment'] && !params.input) {
        error("--entry ${params.entry} needs --input <fastq sheet> (assets/schema_input.json)")
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

//
// meta/samples.csv (assets/schema_samples.json) -> [sample_id: meta]
//
def zgLoadSamples(String path) {
    def rows = samplesheetToList(path, "${projectDir}/assets/schema_samples.json")
    def by_id = [:]
    rows.each { row ->
        def m = (row instanceof List ? row[0] : row) as Map
        if (by_id.containsKey(m.sample_id)) {
            error("duplicate sample_id ${m.sample_id} in ${path}")
        }
        by_id[m.sample_id] = m
    }
    return by_id
}

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
// Per-sample meta for the CRAM workflow from a samples.csv row.
//
def zgSampleMeta(Map row, String pu) {
    def lib = row.rg_lb ?: row.library
    return [
        id         : row.sample_id,
        sample     : row.sample_id,
        library    : row.library,
        source     : row.source,
        role       : row.role,
        donor      : row.donor ?: '',
        taxon      : row.taxon ?: '',
        single_end : false,
        qc_group   : row.library,
        pu         : pu ?: '',
        read_group : zgReadGroup(row.sample_id, lib, row.rg_pl, pu),
    ]
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
// Libraries registered as demultiplexed: assets/registry_seed.csv (PLAN §0: the libraries demuxed before zealgt) plus
// every <store root>/registry/<library>.registry.tsv.
//
def zgRegisteredLibraries() {
    def seed = file(params.registry_seed, checkIfExists: true)
    def libs = [:]
    seed.readLines().drop(1).findAll { line -> line.trim() && !line.startsWith('#') }.each { line ->
        libs[line.tokenize(',')[0].trim()] = "seed (${params.registry_seed})"
    }
    def reg = file("${zgStoreRoot()}/registry")
    if (reg.isDirectory()) {
        reg.listFiles().findAll { f -> f.name.endsWith('.registry.tsv') }.each { f ->
            libs[f.name.replace('.registry.tsv', '')] = "store (${f})"
        }
    }
    return libs
}
