/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Genotype workflow: CRAM store + genotype sheet + run card -> sample QC, discovery, ancestry, union, donor alleles,
    genotypes, reporting (docs/PLAN_pipeline.md §3 rows 2b-8; genotype design agent/20260928_071950_genotype_design.md).
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    --entry <stage> runs that stage only (design §0.1). Its upstream inputs are read from the keyed genotype store
    <store>/genotype/<input_store_key or genotype_store_key>/ (zgStorePath); their existence, the provenance of the CRAMs and
    the stage settings were checked by PIPELINE_INITIALISATION (utils genotype_functions.nf). Outputs go to storeDir
    <store>/genotype/<genotype_store_key>/ (conf/genotype_modules.config). Unit = donor x region; the B73 controls form one
    role group per region. Samples that failed stage 2b (sample_qc.tsv pass = false) are removed before any read consumer.
    This file only wires channels.
----------------------------------------------------------------------------------------
*/
include { SAMPLE_QUALITY_CONTROL } from '../subworkflows/local/sample_quality_control'
include { VARIANT_DISCOVERY      } from '../subworkflows/local/variant_discovery'
include { ANCESTRY_INFERENCE     } from '../subworkflows/local/ancestry_inference'
include { MARKER_UNION_STAGE     } from '../subworkflows/local/marker_union'
include { DONOR_ALLELE_CALLING   } from '../subworkflows/local/donor_allele_calling'
include { GENOTYPE_IMPUTATION    } from '../subworkflows/local/genotype_imputation'
include { GENOTYPE_REPORTING     } from '../subworkflows/local/genotype_reporting'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { zgDonors; zgRegions; zgStorePath; zgFlag; zgMappabilityPrior; zgReferenceDonorTables; zgAnnotationPanels } from '../subworkflows/local/utils_nfcore_zealgt_pipeline/genotype_functions'
include { zgRoleGroup; zgQcKeep; zgDropSamples; zgLineQcFailures; zgExclusionTable; zgReferenceDonorTaxa; zgPriorDonorTaxa } from '../subworkflows/local/utils_nfcore_zealgt_pipeline/genotype_functions'

workflow GENOTYPE {

    take:
    ch_genotype_samples // channel: [ val(meta), cram, crai, metrics, val([mask_r1, mask_r2]) ]

    main:
    def entry      = params.entry
    def donors     = zgDonors()
    def dset       = params.donor_set
    def fasta      = file(params.fasta, checkIfExists: true)
    def ch_ref     = channel.value([[id: fasta.baseName], fasta, file("${fasta}.fai", checkIfExists: true)])
    def ch_lowcopy = channel.value([[id: 'lowcopy'], file(params.lowcopy_bed, checkIfExists: true)])
    def ch_regions = channel.fromList(zgRegions())
    // units as plain lists: donor x region (unit meta) and donor set x region (set meta)
    def units = donors.collectMany { d -> zgRegions().collect { rmeta, r -> [id: "${d}.${rmeta.id}".toString(), donor: d, region: rmeta.id, interval: r] } }
    def sets  = zgRegions().collect { rmeta, r -> [id: "${dset}.${rmeta.id}".toString(), donor_set: dset, region: rmeta.id, interval: r] }
    def ch_units = channel.fromList(units)
    def rpq = zgFlag('read_position_qc')

    // Exclusions are cumulative ("lines fall at every QC", user decision 2026-09-28): stage 2b (sample_qc.tsv) for every entry
    // that reads the CRAMs after it, and stage 4 (line_qc.tsv, LINE_MARKER_QC) for every entry after ancestry_inference.
    def ch_selected = ch_genotype_samples
    if (entry in ['variant_discovery', 'ancestry_inference', 'donor_allele_calling'] || (entry == 'reporting' && rpq)) {
        // an empty table (a stub run's) has no rows: every sample then counts as missing (kept in stub, refused otherwise)
        def ch_qc = channel.fromPath(zgStorePath('sample_qc', '', ''))
            .filter { f -> f.size() > 0 }
            .splitCsv(header: true, sep: '\t')
            .map { r -> [r.sample, r.pass] }
        ch_selected = ch_genotype_samples
            .map { s -> [s[0].id, s] }
            .join(ch_qc, remainder: true)
            .filter { id, s, pass -> s != null && zgQcKeep(id, pass) }
            .map { _id, s, _pass -> s }
    }
    // role groups: donor x region x role (bc1_sample, line) and b73 x region (the B73 controls)
    def ch_groups = ch_selected
        .map { meta, cram, crai, _metrics, mask -> [[meta.role == 'b73_control' ? 'b73' : meta.donor, meta.role], [meta, cram, crai, mask]] }
        .groupTuple()
        .combine(ch_regions)
        .map { key, rows, rmeta, region -> zgRoleGroup(key, rows, rmeta.id, region) }
    if (entry in ['donor_allele_calling', 'reporting']) {
        def ch_line_fail = ch_units.map { u -> [u.id, zgLineQcFailures(zgStorePath('line_qc', u.donor, u.region)).keySet()] }.toList().map { l -> [l.collectEntries()] }
        ch_groups = ch_groups.combine(ch_line_fail).map { g, c, i, ids, m, fails -> zgDropSamples([g, c, i, ids, m], fails[g.unit] ?: [], 'LINE_MARKER_QC') }.filter { grp -> grp != null }
    }
    ch_groups = ch_groups.filter { _g, crams, _crais, _ids, _masks -> crams } // an empty group would give MASK_READ_STARTS no output

    def ch_versions = channel.empty()
    if (entry == 'sample_quality_control') {
        def panel = params.qc_panel ? file(params.qc_panel, checkIfExists: true) : []
        SAMPLE_QUALITY_CONTROL(ch_selected, params.qc_panel ? ch_groups : channel.empty(), params.qc_panel ? ch_regions : channel.empty(), ch_lowcopy, ch_ref, panel, params.min_coverage)
        ch_versions = SAMPLE_QUALITY_CONTROL.out.versions
    }
    else if (entry == 'variant_discovery') {
        def annot = zgAnnotationPanels()
        def ch_annot = channel.value(annot ? [annot.collect { a -> a[0] }, annot.collect { a -> a[1] }] : [[], []])
        VARIANT_DISCOVERY(ch_groups, ch_regions, ch_lowcopy, ch_ref, ch_annot, params.tier_counts_source)
        ch_versions = VARIANT_DISCOVERY.out.versions
    }
    else if (entry == 'ancestry_inference') {
        ANCESTRY_INFERENCE(
            ch_groups.filter { g, _c, _i, _ids, _m -> g.role == 'line' },
            ch_units.map { u -> [u, zgStorePath('step4', u.donor, u.region)] },
            ch_regions, ch_lowcopy, ch_ref, params.rigidity, params.min_markers_factor,
        )
        ch_versions = ANCESTRY_INFERENCE.out.versions
    }
    else if (entry == 'marker_union') {
        def refs = zgReferenceDonorTables()
        MARKER_UNION_STAGE(
            channel.fromList(sets).map { s -> [s, donors.collect { d -> zgStorePath('step4', d, s.region) }, refs.collect { r -> r[1] }] },
            donors, refs.collect { r -> r[0] },
        )
        ch_versions = MARKER_UNION_STAGE.out.versions
    }
    else if (entry == 'donor_allele_calling') {
        def flat = params.mappability_prior_mode == 'flat'
        def ch_taxa = ch_genotype_samples.filter { meta, _c, _i, _m, _k -> meta.role != 'b73_control' }.map { meta, _c, _i, _m, _k -> [meta.donor, meta.taxon ?: ''] }.unique()
        DONOR_ALLELE_CALLING(
            ch_groups,
            channel.fromList(sets).map { s -> [s, zgStorePath('union', '', s.region), zgStorePath('union_sites', '', s.region)] },
            ch_units.map { u -> [u, zgStorePath('segments', u.donor, u.region), zgStorePath('line_qc', u.donor, u.region)] },
            ch_taxa.map { d, t -> [d, flat ? [] : zgMappabilityPrior(t)] },
            ch_taxa.toList().map { l -> zgPriorDonorTaxa(l.collectEntries(), zgReferenceDonorTaxa()) },
            donors, ch_regions, ch_lowcopy, ch_ref,
        )
        ch_versions = DONOR_ALLELE_CALLING.out.versions
    }
    else if (entry == 'genotype_imputation') {
        GENOTYPE_IMPUTATION(ch_units.map { u -> [u, zgStorePath('donor_alleles', u.donor, u.region), zgStorePath('segments', u.donor, u.region), zgStorePath('line_qc', u.donor, u.region)] })
        ch_versions = GENOTYPE_IMPUTATION.out.versions
    }
    else if (entry == 'reporting') {
        GENOTYPE_REPORTING(
            ch_units.map { u -> [u, zgStorePath('genotypes', u.donor, u.region), zgStorePath('segments', u.donor, u.region), zgStorePath('donor_alleles', u.donor, u.region), zgStorePath('line_qc', u.donor, u.region)] },
            rpq ? ch_groups.filter { g, _c, _i, _ids, _m -> g.role != 'b73_control' } : channel.empty(),
            ch_units.map { u -> [u, zgStorePath('markers', u.donor, u.region)] },
            rpq ? ch_regions : channel.empty(), ch_lowcopy, ch_ref,
        )
        ch_versions = GENOTYPE_REPORTING.out.versions
        ch_units.map { u -> ["${u.id}.exclusions.tsv", zgExclusionTable(u)] }
            .collectFile(storeDir: "${params.outdir}/genotype/${params.genotype_store_key}/reporting/${dset}") { item -> item }
    }
    else {
        error("--workflow genotype: unknown --entry '${entry}'")
    }

    //
    // Collate and save software versions (as workflows/cram.nf): topic tuples and versions.yml files
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
    softwareVersionsToYAML(topic_versions.versions_file)
        .mix(topic_versions_string)
        .collectFile(storeDir: "${params.outdir}/pipeline_info", name: "zealgt_genotype_${entry}_software_versions.yml", sort: true, newLine: true)

    emit:
    versions = ch_versions // channel: versions.yml files and [ process, tool, version ] tuples of the stage
}
