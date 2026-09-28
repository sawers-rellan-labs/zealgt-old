// RELATEDNESS_QC — stage 2b (sample_quality_control) identity check before discovery (PLAN §3 row 2b "Relatedness QC"):
// VanRaden-centred kinship of every sample to each donor group on the blind QC panel, from the QC_PANEL_COUNTS tables; no
// hard calls (lines: one random read per site, --seed; BC1 pools and B73 controls: ALT fractions; --method vanraden_af gives
// ALT fractions to all). Flags a sample whose kinship to its own donor falls outside its (donor, role) group (robust z below
// -flag_sd) or that is closer to another donor (templates/estimate_relatedness.py, a module template: hashed by content).
// Runs only when params.qc_panel is set; the blind panel does not exist yet (design §10 item 6), so the workflow skips it and
// the module is tested on a fixture panel. Shared genotype python env (envs/process_aliases.tsv RELATEDNESS_QC ->
// pooled_likelihood_tiers).
// ext.args = --method <relatedness_method> --seed <relatedness_seed> --flag-sd <relatedness_flag_sd> [--closer-margin X
//            --min-sites N --min-group N --regions ...].
process RELATEDNESS_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/../pooled_likelihood_tiers/environment.yml"

    input:
    tuple val(meta), path(counts, stageAs: 'counts/*')
    path panel
    val sample_map

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.relatedness.tsv")       , emit: tsv
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.relatedness_donors.tsv"), emit: donors
    path "${task.ext.prefix ?: meta.id}.relatedness_qc.versions.yml"             , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'estimate_relatedness.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.relatedness.tsv ${prefix}.relatedness_donors.tsv

    cat <<-END_VERSIONS > ${prefix}.relatedness_qc.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
