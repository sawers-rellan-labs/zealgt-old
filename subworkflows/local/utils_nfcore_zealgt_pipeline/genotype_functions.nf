//
// Genotype workflow functions of the utils subworkflow (genotype design §0, §1, §5): entries, run guards, the genotype sample
// sheet, the provenance check, the keyed genotype store and its settings guard. Included by ./main.nf (PIPELINE_INITIALISATION
// calls zgGenotypeGuards and zgGenotypeInputs); workflows/genotype.nf may include the path and region helpers (zgRegions,
// zgGenotypeStore, zgInputStore, zgStorePath, zgReferenceDonorTables, zgAnnotationPanels, zgMappabilityPrior) for wiring.
// Self-contained: it includes nothing from ./main.nf (no circular include).
//

include { samplesheetToList } from 'plugin/nf-schema'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Entries, stage contents
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// The seven genotype entries in stage order (PLAN §3 rows 2b-8). `--entry X` runs stage X only.
def zgGenotypeEntries() {
    return ['sample_quality_control', 'variant_discovery', 'ancestry_inference', 'marker_union', 'donor_allele_calling',
            'genotype_imputation', 'reporting']
}

// Entries whose outputs are named by --donor_set (design §1.3)
def zgSetEntries() {
    return ['marker_union', 'donor_allele_calling', 'genotype_imputation', 'reporting']
}

// Run-card parameters of each stage (the settings guard, design §0.3 / §5). A stage's stored settings must match these.
def zgStageParamNames() {
    def tiers = ['tier_eps0', 'tier_prior', 'tier_plants', 'tier_zero_class_llr', 'tier_zero_class_min_reads', 'tier_eps_floor',
                 'tier_llr_a', 'tier_llr_b', 'tier_llr_c', 'tier_llr_ref', 'tier_ref_min_depth', 'tier_a_min_pools_alt',
                 'tier_a_single_pool_min_alt', 'tier_ref_min_pools', 'hidepth_factor', 'af_gt_half_p',
                 'tier_a_single_pool_max_pools', 'tier_af_gt_half_min_depth', 'tier_inconsistent_min_alt', 'tier_inconsistent_min_depth']
    def reads = ['fasta', 'pileup_args', 'mask_read_starts']
    return [
        sample_quality_control: reads + ['b73_controls', 'min_coverage', 'qc_panel', 'panel_min_markers', 'relatedness_method',
                                         'relatedness_seed', 'relatedness_flag_sd', 'donor_content_expected', 'donor_content_flag_low',
                                         'relatedness_qc', 'donor_content_qc', 'sample_qc_fail_on'],
        variant_discovery     : reads + ['b73_controls', 'lowcopy_bed', 'crisp_args', 'veto_min_alt_reads', 'tier_counts_source',
                                         'annotation_panels', 'tier_witness_zero_class'] + tiers,
        ancestry_inference    : reads + ['lowcopy_bed', 'rigidity', 'min_markers_factor', 'rtiger_drop_invariant_sites'],
        marker_union          : ['reference_donor_tables'],
        donor_allele_calling  : reads + ['b73_controls', 'lowcopy_bed', 'gap_alt_posterior', 'gap_prior_w', 'gap_prior_scope',
                                         'gap_prior_source', 'gap_prior_fixed', 'reference_donor_tables', 'reference_donor_taxa',
                                         'eps_prior_alpha',
                                         'eps_prior_beta', 'b73_lines_alt_p', 'b73_lines_min_alt', 'lambda_sites', 'c_grid_max',
                                         'c_grid_step', 'ks_floor', 'mappability_priors', 'mappability_prior_mode'] + tiers,
        genotype_imputation   : ['imputation_method', 'phg_inbreeding', 'phg_prob_same_gamete'],
        reporting             : ['reporting_expectation', 'breakpoint_window_markers', 'read_position_qc'],
    ]
}

// Module directories whose code (main.nf + templates/*) each stage runs (design §2); hashed into the stage settings with
// zgStageWiring (zgStageCode).
def zgStageModules() {
    def lcl = { names -> names.collect { n -> "modules/local/${n}".toString() } }
    return [
        sample_quality_control: lcl.call(['region_bed', 'mask_read_starts', 'allele_counts', 'min_coverage', 'coverage_qc', 'relatedness_qc',
                                     'donor_content_qc', 'sample_qc_table']),
        variant_discovery     : lcl.call(['region_bed', 'mask_read_starts', 'witness_pool', 'crisp', 'witness_veto', 'allele_counts',
                                     'pooled_likelihood_tiers']) + ['modules/nf-core/bcftools/view'],
        ancestry_inference    : lcl.call(['region_bed', 'mask_read_starts', 'allele_counts', 'rtiger_markers', 'line_marker_qc', 'rtiger']),
        marker_union          : lcl.call(['marker_union']),
        donor_allele_calling  : lcl.call(['region_bed', 'mask_read_starts', 'allele_counts', 'pooled_likelihood_tiers',
                                     'gap_filling_bc1', 'gap_filling_lines', 'donor_founder']),
        genotype_imputation   : lcl.call(['rasterize']),
        reporting             : lcl.call(['sample_labels', 'genotype_summary', 'chromosome_painting', 'read_position_qc']),
    ]
}

// Wiring and module config of each stage, hashed into its settings next to the modules (PLAN §2 hash hygiene): the stage's
// subworkflow, workflows/genotype.nf and conf/genotype_modules.config (ext.args / ext.prefix / ext.when / storeDir). An
// ext.prefix or storeDir change under an existing key is refused like a code change. conf/genotype_hazel.config is not
// hashed: it holds resources only (cpus / memory / time; the scripts read the allocation from Slurm, task hashes keep).
def zgStageWiring() {
    def swf = [sample_quality_control: 'sample_quality_control', variant_discovery: 'variant_discovery',
               ancestry_inference: 'ancestry_inference', marker_union: 'marker_union', donor_allele_calling: 'donor_allele_calling',
               genotype_imputation: 'genotype_imputation', reporting: 'genotype_reporting']
    return swf.collectEntries { stage, dir -> [(stage): ["subworkflows/local/${dir}/main.nf".toString(), 'workflows/genotype.nf', 'conf/genotype_modules.config']] }
}

// Every code path hashed into a stage's settings: module dirs, then the wiring files
def zgStageCode(String stage) {
    return zgStageModules()[stage] + zgStageWiring()[stage]
}

// Upstream store outputs each entry reads (design §1.3), and the entry that writes each kind.
// (reporting reads the markers only for the read-position QC; zgCheckUpstream adds them when it runs)
def zgUpstreamKinds() {
    return [
        variant_discovery   : ['sample_qc'],
        ancestry_inference  : ['sample_qc', 'step4'],
        marker_union        : ['step4'],
        donor_allele_calling: ['sample_qc', 'step4', 'segments', 'line_qc', 'union', 'union_sites'],
        genotype_imputation : ['donor_alleles', 'segments', 'line_qc', 'union'],
        reporting           : ['sample_qc', 'genotypes', 'genotypes_matrix', 'segments', 'line_qc', 'donor_alleles'],
    ]
}

def zgKindProducer() {
    return [sample_qc: 'sample_quality_control', step4: 'variant_discovery', segments: 'ancestry_inference',
            line_qc: 'ancestry_inference', markers: 'ancestry_inference', union: 'marker_union', union_sites: 'marker_union',
            donor_alleles: 'donor_allele_calling', genotypes: 'genotype_imputation', genotypes_matrix: 'genotype_imputation']
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Params helpers: lists, regions, store paths
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Comma-separated param -> list of trimmed, non-empty values (as zgList in ./main.nf)
def zgGtList(value) {
    return value ? value.toString().tokenize(',')*.trim().findAll { v -> v } : []
}

// "name=path,name=path" -> [[name, path], ...]
def zgNamedPaths(String param_name) {
    return zgGtList(params[param_name]).collect { item ->
        def i = item.indexOf('=')
        i > 0 && i < item.length() - 1 ? [item.substring(0, i).trim(), item.substring(i + 1).trim()] : error("--${param_name}: '${item}' is not <name>=<path>")
    }
}

def zgDonors() {
    return zgGtList(params.donors).unique()
}

// "chr10" or "chr10:1-20000000" -> [chrom, start, end] (start/end null for a whole chromosome)
def zgParseRegion(String region) {
    def m = region =~ /^([A-Za-z0-9_.]+)(?::(\d+)-(\d+))?$/
    if (!m.matches()) {
        error("--regions: '${region}' is not <chrom> or <chrom>:<start>-<end>")
    }
    def start = m.group(2) ? m.group(2).toLong() : null
    def end   = m.group(3) ? m.group(3).toLong() : null
    if (start != null && (start < 1 || end < start)) {
        error("--regions: '${region}' needs 1 <= start <= end")
    }
    return [m.group(1), start, end]
}

// Region label used in file names and unit ids: chr10 -> chr10, chr10:1-20000000 -> chr10_1-20000000 (design §1.4)
def zgRegionLabel(String region) {
    return region.replace(':', '_')
}

// The run's regions as channel items: [ [id: <label>], <region string> ]
def zgRegions() {
    return zgGtList(params.regions).unique().collect { r -> [[id: zgRegionLabel(r)], r] }
}

// <store>/genotype/<genotype_store_key>: where this run's stage writes (storeDir root of every genotype process)
def zgGenotypeStore() {
    return "${params.store}/genotype/${params.genotype_store_key}".toString()
}

// <store>/genotype/<input_store_key or genotype_store_key>: where upstream stage outputs are read
def zgInputStore() {
    return "${params.store}/genotype/${params.input_store_key ?: params.genotype_store_key}".toString()
}

// Path of one upstream output relative to a genotype store (design §1.3 layout; conf/genotype_modules.config must match)
def zgStoreRel(String kind, String donor, String label) {
    def dset = params.donor_set ?: ''
    // Names = the module outputs under conf/genotype_modules.config (prefix = unit / set / cohort id). The genotype table has
    // its own `.genotypes` suffix because GENOTYPE_SUMMARY and RASTERIZE stage it next to the donor-allele table.
    def rel = [
        sample_qc    : 'sample_qc/cohort.sample_qc.tsv',
        step4        : "step4/${donor}.${label}.sites.tsv.gz",
        segments     : "ancestry/${donor}.${label}.segments.csv",
        line_qc      : "ancestry/${donor}.${label}.line_qc.tsv",
        markers      : "ancestry/${donor}.${label}.tierA_sites.tsv",
        union        : "union/${dset}.${label}.tsv.gz",
        union_sites  : "union/${dset}.${label}.union_sites.tsv",
        donor_alleles: "donor_alleles/${dset}/${donor}.${label}.tsv.gz",
        genotypes    : "genotypes/${dset}/${donor}.${label}.genotypes.tsv.gz",
        genotypes_matrix: "genotypes/${dset}/${donor}.${label}.genotypes.matrix.tsv.gz",
    ][kind]
    return rel ? rel.toString() : error("zgStoreRel: unknown kind '${kind}'")
}

// An upstream output in the input store as a file (for wiring; existence is checked at initialisation)
def zgStorePath(String kind, String donor, String label) {
    return file("${zgInputStore()}/${zgStoreRel(kind, donor, label)}")
}

// --reference_donor_tables -> [[donor, file], ...] (read-only step-4 tables of donors not called in this run, design §2.4)
def zgReferenceDonorTables() {
    return zgNamedPaths('reference_donor_tables').collect { d, p -> [d, file(p)] }
}

// --reference_donor_taxa -> [donor: taxon] (the reference donors are not in the sheet, so they have no taxon otherwise)
def zgReferenceDonorTaxa() {
    return zgNamedPaths('reference_donor_taxa').collectEntries { d, t -> [(d): t] }
}

// GAP_FILLING_BC1 donor_taxa: the run donors' sheet taxa plus the reference donors' (gap_prior_scope same_taxon keeps a
// prior donor only when its taxon equals the called donor's); logged so the run shows which taxa the prior used
def zgPriorDonorTaxa(Map run_taxa, Map reference_taxa) {
    def taxa = run_taxa + reference_taxa
    log.info("zealgt genotype: gap-prior donor taxa ${taxa.collect { d, t -> "${d}=${t ?: '(none)'}" }.join(',')} (gap_prior_scope ${params.gap_prior_scope})")
    return taxa
}

// --annotation_panels -> [[name, file], ...]
def zgAnnotationPanels() {
    return zgNamedPaths('annotation_panels').collect { n, p -> [n, file(p)] }
}

// --registry as recorded in the reporting labels table (SAMPLE_LABELS): relative to the pipeline directory when inside it,
// so a second clone records (and hashes) the same value. The registry is recorded, not guarded (zgStageParamNames): the
// edge translation uses the current registry, and a registry commit must not refuse a rerun under the same key.
def zgRegistrySource() {
    def reg = file(params.registry).toAbsolutePath().normalize()
    def root = file(projectDir.toString()).toAbsolutePath().normalize()
    return (reg.startsWith(root) ? root.relativize(reg) : reg).toString()
}

// Mappability prior of a taxon: <mappability_priors>/<taxon>.prior.tsv
def zgMappabilityPrior(String taxon) {
    return file("${params.mappability_priors}/${taxon}.prior.tsv")
}

// Boolean params (Nextflow 26 hands CLI values over as strings: "--mask_read_starts false"); the schema allows true / false only
def zgFlag(String name) {
    return params[name].toString().toLowerCase() == 'true'
}

def zgMaskReadStarts() {
    return zgFlag('mask_read_starts')
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Wiring helpers of workflows/genotype.nf: role groups and the cumulative sample exclusions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    User decision 2026-09-28 ("lines fall at every QC"): a sample excluded at any QC point stays excluded in every later
    stage that reads samples. Stage 2b: sample_qc.tsv pass = false (MIN_COVERAGE, and the panel checks of sample_qc_fail_on).
    Stage 4: line_qc.tsv line_pass = false (LINE_MARKER_QC coverage floor). No stage re-admits a sample dropped earlier.
*/

// One role group: [ gmeta, [crams], [crais], [ids], [[mask_r1, mask_r2], ...] ] from [ meta, cram, crai, mask ] rows, sorted by
// id. gmeta carries the unit (donor x region, or b73 x region) for joins; modules read only gmeta.id.
def zgRoleGroup(List key, List rows, String label, String region) {
    def (who, role) = key
    def sorted = rows.sort { r -> r[0].id }
    def unit   = "${who}.${label}".toString()
    def tag    = [bc1_sample: 'bc1', line: 'lines', b73_control: 'b73'][role]
    def gmeta  = [id: "${unit}.${tag}".toString(), unit: unit, donor: who == 'b73' ? '' : who, region: label, interval: region,
                  role: role, taxon: sorted[0][0].taxon ?: '']
    return [gmeta, sorted.collect { r -> r[1] }, sorted.collect { r -> r[2] }, sorted.collect { r -> r[0].id }, sorted.collect { r -> r[3] }]
}

// A role group without the samples in `drop` (log line per dropped sample); null when nothing is left
def zgDropSamples(List group, Collection drop, String why) {
    def (g, crams, crais, ids, masks) = group
    def keep = (0..<ids.size()).findAll { i -> !(ids[i] in drop) }
    ids.findAll { s -> s in drop }.each { s -> log.info("zealgt genotype: ${s} excluded by ${why} (${g.unit})") }
    return keep ? [g, keep.collect { i -> crams[i] }, keep.collect { i -> crais[i] }, keep.collect { i -> ids[i] }, keep.collect { i -> masks[i] }] : null
}

// Stage-2b decision of one sample: pass = true keeps it. A sample missing from the table stops a real run (stage 2b was run for
// another cohort); a stub run's table is empty, so there every sample is kept (logged).
def zgQcKeep(String id, pass) {
    if (pass == null) {
        workflow.stubRun ? log.warn("zealgt genotype: ${id} not in sample_qc.tsv (stub run: kept)") : error("${id} is not in sample_qc.tsv of the input store: run --entry sample_quality_control for these donors first")
        return true
    }
    if (pass.toString().toLowerCase() != 'true') {
        log.info("zealgt genotype: ${id} excluded by sample QC")
    }
    return pass.toString().toLowerCase() == 'true'
}

// Rows of a header TSV as maps ([] for a missing or empty file, e.g. a stub output)
def zgReadTsv(path) {
    def f = file(path)
    if (!f.exists() || f.size() == 0) {
        return []
    }
    def lines = f.readLines().findAll { l -> l }
    def hdr = lines ? lines[0].tokenize('\t') : []
    return lines.drop(1).collect { l ->
        def v = l.split('\t', -1)
        (0..<hdr.size()).collectEntries { i -> [(hdr[i]): i < v.size() ? v[i] : ''] }
    }
}

// Lines excluded by LINE_MARKER_QC in one unit: [ sample: reason ] (line_qc.tsv has one row per line x contig)
// line_qc.tsv contract (LINE_MARKER_QC): columns sample and line_pass (true|false), one row per contig; the reasons of the
// failing contigs are joined.
def zgLineQcFailures(path) {
    def rows = zgReadTsv(path)
    if (rows && !(rows[0].containsKey('sample') && rows[0].containsKey('line_pass'))) {
        error("line_qc ${path}: needs the LINE_MARKER_QC columns sample and line_pass")
    }
    return rows.findAll { r -> r.line_pass.toLowerCase() != 'true' }
        .groupBy { r -> r.sample }
        .collectEntries { s, rs -> [(s): rs.collect { r -> r.reason }.findAll { w -> w && w != '.' }.unique().join(',') ?: 'line_qc'] }
}

// Exclusion table of one unit for reporting: every sample of the donor dropped at 2b or at stage 4, with stage and reason
def zgExclusionTable(Map u) {
    def rows = zgReadTsv(zgStorePath('sample_qc', '', '')).findAll { r -> r.donor == u.donor && r.pass?.toLowerCase() != 'true' }
        .collect { r -> [r.sample, r.role, 'sample_quality_control', r.reasons ?: '.'] }
    rows += zgLineQcFailures(zgStorePath('line_qc', u.donor, u.region)).collect { s, why -> [s, 'line', 'ancestry_inference', why] }
    return (['sample\trole\tstage\treason'] + rows.collect { r -> r.join('\t') }).join('\n') + '\n'
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Run guards (the schema already checked types, patterns and enums)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def zgGenotypeGuards() {
    def entry = params.entry
    // `--b73_controls ''` or a bare `--donors` reaches the pipeline as true (boolean or string), not as an empty or missing value
    def valueless = ['genotype_store_key', 'input_store_key', 'donors', 'donor_set', 'regions', 'b73_controls', 'qc_panel',
                     'annotation_panels', 'reference_donor_tables', 'reference_donor_taxa', 'mappability_priors'].findAll { p -> params[p] != null && params[p].toString() == 'true' }
    if (valueless) {
        error("${valueless.collect { p -> "--${p}" }.join(', ')} given without a value (an empty value on the command line becomes 'true'); set it in the run card, or null there to leave it unset")
    }
    def required =['genotype_store_key', 'donors', 'regions'] + (entry in zgSetEntries() ? ['donor_set'] : []) +
                   (entry == 'donor_allele_calling' ? ['mappability_priors'] : [])
    def missing = required.findAll { p -> !params[p] }
    if (missing) {
        error("--workflow genotype --entry ${entry} needs ${missing.collect { p -> "--${p}" }.join(', ')} (set them in the run card, -params-file docs/runs/<run>.yml)")
    }
    if (entry == 'genotype_imputation' && params.imputation_method != 'raster') {
        error("--imputation_method ${params.imputation_method}: the PHG path is not implemented yet (WP-PHG); use raster")
    }
    if (!zgGtList(params.b73_controls) && !workflow.stubRun) {
        error("--b73_controls is empty: the B73 control pools are the zero class of step 4 (design §1.4); an empty set is allowed only in a stub run")
    }
    if (!file(params.cram_store).isDirectory()) {
        error("--cram_store ${params.cram_store} is not a directory")
    }
    def bed = file(params.lowcopy_bed)
    if (!bed.isFile()) {
        error("--lowcopy_bed ${params.lowcopy_bed} does not exist")
    }
    zgCheckRegions(bed)
    if (params.qc_panel && !file(params.qc_panel).isFile()) {
        error("--qc_panel ${params.qc_panel} does not exist")
    }
    def donors = zgDonors()
    zgNamedPaths('reference_donor_tables').each { d, p ->
        if (d in donors) {
            error("--reference_donor_tables names ${d}, a donor called in this run (--donors): reference tables are for donors not called here")
        }
        if (!file(p).isFile()) {
            error("--reference_donor_tables ${d}=${p} does not exist")
        }
    }
    def ref_donors = zgNamedPaths('reference_donor_tables').collect { d, _p -> d }
    def ref_taxa = zgReferenceDonorTaxa()
    (ref_taxa.keySet() - ref_donors).each { d ->
        error("--reference_donor_taxa names ${d}, which is not a donor of --reference_donor_tables")
    }
    if (params.entry == 'donor_allele_calling' && params.gap_prior_scope == 'same_taxon' && params.gap_prior_source == 'other_donors') {
        def untaxed = ref_donors.findAll { d -> !ref_taxa[d] }
        if (untaxed) {
            error("--gap_prior_scope same_taxon: reference donor(s) ${untaxed.join(', ')} have no taxon and would leave the prior; set --reference_donor_taxa ${untaxed.collect { d -> "${d}=<taxon>" }.join(',')}")
        }
    }
    zgNamedPaths('annotation_panels').findAll { _n, p -> !file(p).isFile() }.each { n, p -> error("--annotation_panels ${n}=${p} does not exist") }
    if (params.mappability_priors && !file(params.mappability_priors).isDirectory()) {
        error("--mappability_priors ${params.mappability_priors} is not a directory")
    }
}

// Every region's chromosome must be in the lowcopy BED (design §10 item 7) and, when the .fai is there, inside the chromosome.
def zgCheckRegions(bed) {
    def chroms = [] as Set
    bed.eachLine { line ->
        if (line && !line.startsWith('#') && !line.startsWith('track') && !line.startsWith('browser')) {
            chroms << line.tokenize('\t')[0]
        }
    }
    def fai = file("${params.fasta}.fai")
    def lengths = [:]
    if (fai.isFile()) {
        fai.eachLine { line ->
            def f = line.tokenize('\t')
            lengths[f[0]] = f[1].toLong()
        }
    }
    zgGtList(params.regions).each { r ->
        def (chrom, _start, end) = zgParseRegion(r)
        if (!(chrom in chroms)) {
            error("--regions ${r}: ${chrom} has no range in --lowcopy_bed ${params.lowcopy_bed} (chromosomes there: ${chroms.sort().take(10).join(', ')})")
        }
        if (lengths && !lengths.containsKey(chrom)) {
            error("--regions ${r}: ${chrom} is not in ${fai}")
        }
        if (lengths && end != null && end > lengths[chrom]) {
            error("--regions ${r}: end ${end} is past the end of ${chrom} (${lengths[chrom]})")
        }
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Inputs: genotype sheet -> stored CRAMs (+ provenance check, upstream check, settings guard)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// The genotype samples of this run: the included sheet rows of --donors (bc1_sample, line) plus the --b73_controls rows ->
// [ meta, cram, crai, metrics, [mask_r1, mask_r2] ], files resolved as <cram_store>/<store_dir>/<sample_id>.* and checked here
// (never inside a subworkflow). meta = [id, sample, role, donor, taxon, single_end: false]; the masks are 0 / 0 when
// --mask_read_starts is false (same code path, design Decision 6).
//
def zgGenotypeInputs() {
    def entry   = params.entry
    def donors  = zgDonors()
    def b73     = zgGtList(params.b73_controls).unique()
    def rows    = samplesheetToList(params.genotype_input, "${projectDir}/assets/schema_genotype.json").collect { row -> (row instanceof List ? row[0] : row) as Map }
    def dups    = b73.findAll { s -> rows.find { r -> r.sample_id == s && r.role != 'b73_control' } }
    if (dups) {
        error("--b73_controls ${dups} are rows of ${params.genotype_input} whose role is not b73_control")
    }
    def included = rows.findAll { r -> r.include }
    def selected = included.findAll { r -> (r.role != 'b73_control' && r.donor in donors) || (r.role == 'b73_control' && r.sample_id in b73) }
    donors.each { d ->
        ['bc1_sample', 'line'].findAll { role -> !selected.find { r -> r.donor == d && r.role == role } }.each { role ->
            error("donor ${d}: no included ${role} rows in ${params.genotype_input}")
        }
    }
    def missing_b73 = b73 - selected.collect { r -> r.sample_id }
    if (missing_b73) {
        error("--b73_controls ${missing_b73}: not included b73_control rows of ${params.genotype_input}")
    }
    def masks = zgMaskReadStarts()
    def out = []
    def missing = []
    def origins = [:]
    selected.each { r ->
        def dir = "${params.cram_store}/${r.store_dir}"
        def files = ['cram', 'cram.crai', 'CollectWgsMetrics.coverage_metrics', 'provenance.json'].collect { ext -> file("${dir}/${r.sample_id}.${ext}") }
        files.findAll { f -> !f.exists() }.each { f -> missing << f.toString() }
        if (files.every { f -> f.exists() }) {
            origins[r.sample_id] = zgCheckProvenance(r.sample_id, files[3])
            def meta = [id: r.sample_id, sample: r.sample_id, role: r.role, donor: r.donor ?: '', taxon: r.taxon ?: '', single_end: false]
            out << [meta, files[0], files[1], files[2], masks ? [r.mask_r1 as Integer, r.mask_r2 as Integer] : [0, 0]]
        }
    }
    if (missing) {
        error("${missing.size()} stored files missing under --cram_store ${params.cram_store} (run the CRAM workflow first, e.g. --workflow cram --entry markdup_import): ${missing.take(8).join(', ')}${missing.size() > 8 ? ', ...' : ''}")
    }
    zgCheckUpstream(entry, donors)
    zgStageSettings(entry, zgStageUnits(entry, selected, donors, origins))
    def kinds = origins.values().countBy { o -> o }
    log.info("zealgt genotype: --entry ${entry}, ${out.size()} samples (donors ${donors.join(',')}; b73 ${b73.join(',') ?: 'none'}), regions ${zgGtList(params.regions).join(',')}, store ${zgGenotypeStore()} (reads ${zgInputStore()}), origins ${kinds}, read-start masks ${masks ? 'from the sheet' : 'off (0/0)'}")
    return out
}

//
// PLAN §3 (line 113): the CRAM's provenance record must match the current read-processing settings. Checked: markdup
// (= samtools markdup ${params.markdup_args}). Recorded: origin.kind (demux | import) and origin.input_filters. With
// --provenance_check warn a mismatch is only logged. Returns "<kind>|<input_filters>" for the settings guard.
//
def zgCheckProvenance(String id, prov) {
    def rec
    try {
        rec = new groovy.json.JsonSlurper().parseText(prov.text)
    } catch (Exception e) {
        error("${prov}: not a JSON provenance record (${e.message})")
    }
    def expected = "samtools markdup ${params.markdup_args}".toString()
    def problems = []
    if (rec.markdup != expected) {
        problems << "markdup '${rec.markdup}' (current settings: '${expected}')"
    }
    if (rec.sample && rec.sample != id) {
        problems << "sample '${rec.sample}' (sheet: ${id})"
    }
    if (problems) {
        def msg = "provenance of ${id} (${prov}) does not match the current read-processing settings: ${problems.join('; ')}"
        params.provenance_check == 'warn' ? log.warn(msg) : error("${msg} (--provenance_check warn to proceed)")
    }
    def origin = rec.origin instanceof Map ? rec.origin : [:]
    return "${origin.kind ?: 'unknown'}|${origin.input_filters ?: ''}".toString()
}

//
// --entry X runs stage X only: its store inputs must already be there (PLAN §2 principle 2). A missing input stops the run and
// names the entry to run first.
//
def zgCheckUpstream(String entry, List donors) {
    def labels = zgRegions().collect { rmeta, _r -> rmeta.id }
    def missing = []
    def kinds = (zgUpstreamKinds()[entry] ?: []) + (entry == 'reporting' && zgFlag('read_position_qc') ? ['markers'] : [])
    kinds.each { kind ->
        def rels = kind == 'sample_qc'             ? [zgStoreRel(kind, '', '')] :
                   kind in ['union', 'union_sites'] ? labels.collect { l -> zgStoreRel(kind, '', l) } :
                                         donors.collectMany { d -> labels.collect { l -> zgStoreRel(kind, d, l) } }
        rels.findAll { rel -> !file("${zgInputStore()}/${rel}").exists() }.each { rel -> missing << [rel, zgKindProducer()[kind]] }
    }
    if (missing) {
        def first = zgGenotypeEntries().find { e -> e in missing.collect { m -> m[1] } }
        error("--entry ${entry}: ${missing.size()} inputs missing in ${zgInputStore()}: ${missing.take(6).collect { m -> "${m[0]} (from ${m[1]})" }.join(', ')}${missing.size() > 6 ? ', ...' : ''}. Run --entry ${first} first with this store key (or point --input_store_key at the key that has them)")
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Keyed genotype store: settings guard (review #7, design Decision 3)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    <store>/genotype/<key>/settings/<stage>.json holds the stage's parameters, the sha256 of its modules' code and, per unit
    (donor x region, set x region, or the cohort), the sample rows it was run on. A later run with the same key must agree on
    parameters and code, and on the rows of every unit it shares with the stored settings; new units are added. Otherwise the
    run is refused and the message names the differing fields (storeDir would silently keep the old outputs).
*/

// Parameter values as comparable strings (numbers normalised: 2, "2" and 2.0 compare equal); files hashed where the design
// asks for it (reference donor tables, mappability priors).
def zgSettingsValue(String name) {
    def v = params[name]
    if (v == null || v == '') {
        return ''
    }
    def s = v.toString().trim()
    if (s ==~ /-?\d+(\.\d+)?([eE][-+]?\d+)?/) {
        return new BigDecimal(s).stripTrailingZeros().toPlainString()
    }
    if (name == 'reference_donor_tables') {
        return zgNamedPaths(name).collect { d, p -> "${d}=${p} sha256:${zgFileDigest(file(p))}" }.join(',')
    }
    if (name == 'mappability_priors') {
        def dir = file(s)
        def priors = dir.isDirectory() ? dir.listFiles().findAll { f -> f.name.endsWith('.prior.tsv') }.sort { f -> f.name } : []
        return ([s] + priors.collect { f -> "${f.name} sha256:${zgFileDigest(f)}" }).join(',')
    }
    return s
}

def zgFileDigest(f) {
    def md = java.security.MessageDigest.getInstance('SHA-256')
    f.withInputStream { stream -> stream.eachByte(1 << 16) { buf, n -> md.update(buf, 0, n) } }
    return md.digest().encodeHex().toString()
}

// sha256 of a module directory's main.nf and templates/*, or of one file (content and file names, not the checkout path)
def zgModuleDigest(String rel) {
    def dir = file("${projectDir}/${rel}")
    if (!dir.exists()) {
        return 'absent'
    }
    def tdir = dir.resolve('templates')
    def files = dir.isFile() ? [dir] :
        [dir.resolve('main.nf')] + (tdir.isDirectory() ? tdir.listFiles().findAll { f -> f.isFile() }.sort { f -> f.name } : [])
    def md = java.security.MessageDigest.getInstance('SHA-256')
    files.findAll { f -> f.exists() }.each { f ->
        md.update("${f.name}\n".toString().getBytes('UTF-8'))
        md.update(f.bytes)
    }
    return md.digest().encodeHex().toString()
}

// Units of a stage and the sample rows behind each (design §0.3: a changed sample list under the same key is refused)
def zgStageUnits(String stage, List rows, List donors, Map origins) {
    def rec = { r -> "${r.sample_id}|${r.role}|${r.donor ?: ''}|${r.store_dir}|mask ${r.mask_r1}/${r.mask_r2}|${origins[r.sample_id]}".toString() }
    def labels = zgRegions().collect { rmeta, _r -> rmeta.id }
    def b73 = rows.findAll { r -> r.role == 'b73_control' }.collect(rec).sort()
    def of_donor = { d -> rows.findAll { r -> r.donor == d && r.role != 'b73_control' }.collect(rec).sort() }
    def units = [:]
    if (stage == 'sample_quality_control') {
        units['cohort'] = labels.collect { l -> "region|${l}".toString() } + rows.collect(rec).sort()
    }
    else if (stage in ['marker_union', 'donor_allele_calling']) {
        def refs = zgNamedPaths('reference_donor_tables').collect { d, _p -> "reference|${d}".toString() }
        def samples = stage == 'donor_allele_calling' ? donors.collectMany { d -> of_donor.call(d) } + b73 : []
        labels.each { l -> units["${params.donor_set}.${l}".toString()] = donors.collect { d -> "donor|${d}".toString() } + refs + samples }
    }
    else {
        def prefix = stage in zgSetEntries() ? "${params.donor_set}/" : ''
        donors.each { d -> labels.each { l -> units["${prefix}${d}.${l}".toString()] = of_donor.call(d) + (stage == 'variant_discovery' ? b73 : []) } }
    }
    return units
}

def zgStageSettings(String stage, Map units) {
    def key = params.genotype_store_key
    def path = file("${zgGenotypeStore()}/settings/${stage}.json")
    def current = [
        params: zgStageParamNames()[stage].collectEntries { n -> [(n): zgSettingsValue(n)] } + [input_store_key: (params.input_store_key ?: key).toString()],
        code  : zgStageCode(stage).collectEntries { m -> [(m): zgModuleDigest(m)] },
    ]
    def stored = null
    if (path.exists()) {
        try {
            stored = new groovy.json.JsonSlurper().parseText(path.text)
        } catch (Exception e) {
            error("${path}: unreadable settings file (${e.message})")
        }
    }
    def stored_units = stored?.units ?: [:]
    if (stored) {
        def diffs = []
        ['params', 'code'].each { part ->
            def a = stored[part] ?: [:]
            def b = current[part]
            (a.keySet() + b.keySet()).unique().sort().findAll { k -> a[k] != b[k] }.each { k ->
                diffs << "${part}.${k}: stored '${a[k] ?: '(unset)'}' vs now '${b[k] ?: '(unset)'}'"
            }
        }
        units.findAll { id, samples -> stored_units.containsKey(id) && stored_units[id] != samples }.each { id, samples ->
            def gone = stored_units[id] - samples
            def added = samples - stored_units[id]
            diffs << "unit ${id}: sample rows differ (stored only: ${gone.take(3)}${gone.size() > 3 ? '...' : ''}; now only: ${added.take(3)}${added.size() > 3 ? '...' : ''})"
        }
        if (diffs) {
            error("genotype store key '${key}', stage ${stage}: settings differ from ${path} (review #7: storeDir would keep outputs made with other settings):\n  " + diffs.join('\n  ') + "\nUse a new --genotype_store_key, or rerun with the stored settings.")
        }
        if (units.every { id, _s -> stored_units.containsKey(id) }) {
            return
        }
    }
    def doc = [stage: stage, genotype_store_key: key] + current + [
        units      : stored_units + units,
        written_by : [run_name: workflow.runName, session_id: workflow.sessionId.toString(), run_id: params.run_id ?: '',
                      stub: workflow.stubRun, first_written: stored?.written_by?.first_written ?: new Date().format("yyyy-MM-dd'T'HH:mm:ssZ")],
    ]
    path.parent.mkdirs()
    path.text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(doc)) + '\n'
    log.info("zealgt genotype: ${stored ? 'added units to' : 'wrote'} ${path}")
}
