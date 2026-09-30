// POOLED_LIKELIHOOD_TIERS — step 4 of discovery: the pooled likelihood ratio, flags and tiers per donor and site (genotype
// design §2.2; math supplement "Per-donor variant discovery"; rewrite of the maths of zealbc1
// PHG/bin/pilot_step4_postfilter_llr.py). Also included as JOINT_POOLED_LIKELIHOOD (stage 6, all donors of a set at the
// union sites, --input-format counts, no veto; the `include ... as` aliases of the workflows).
//
// Owner of the python environment: every genotype python module runs in this module's environment.yml (design §0.8).
//
// Inputs
//   [meta, calls, extra_counts, sites]  calls = the vetoed CRISP VCF (crisp_vcf) or the donors' ALLELE_COUNTS tables
//                                       (counts); extra_counts = ALLELE_COUNTS tables of the B73 controls; sites = the
//                                       site list for counts mode ([] with a VCF)
//   sample_map                          [[sample, donor, taxon, role], ...], role bc1_sample | witness | b73_control
//                                       (zealbc1 map.tsv: witness -> donor 'BC2S3', B73 controls -> donor 'B73')
//   region                              'chr' or 'chr:start-end'; the file label is the region with ':' -> '_'
//   [annotation_names, annotations]     optional annotation site lists (chrom pos ref alt) -> in_<name> columns; [[], []]
// Outputs (stored in <store>/genotype/<key>/step4 or joint_step4/<set>, conf/genotype_modules.config)
//   <donor>.<label>.sites.tsv.gz per bc1_sample donor of the map, <prefix>.summary.tsv, .pool_qc.tsv, .run_info.txt and a
//   versions.yml (a module template: `eval` outputs need a Bash script). Column contract of the sites table (stage 6 depends on it): chrom pos ref alt n a
//   n_pools n_pools_alt eps n0 a0 self_in_zero LLR logodds posterior tier flags [in_<annotation>...] pool_counts; n0 / a0 =
//   zero-class reads behind eps, logodds = LLR + logit(prior) at full precision. The sites output names the donors
//   explicitly (brace glob), so a store directory shared by many donors never satisfies one donor's task with another's table.
// ext.args = the template's options (--input-format, --eps0, --prior, --plants, --zero-class-*, --eps-floor, --llr-*,
// --ref-*, --a-*, --hidepth-factor, --af-gt-half-*, --inconsistent-*, --[no-]witness-zero-class, --keep-zero-depth), from
// the tier_* run-card params. Python standard library only (templates/score_pooled_likelihood.py).

// Output pattern of the per-donor sites tables over the map's bc1_sample donors: '{d1,d2}.<label>.sites.tsv.gz'.
def zgTierTables(sample_map, region) {
    def donors = sample_map.findAll { row -> row[3] == 'bc1_sample' }.collect { row -> row[1] as String }.unique().sort()
    def label  = (region as String).replace(':', '_')
    // a one-element brace glob is not expanded by Nextflow: one donor gives the literal file name
    return donors.size() == 1 ? "${donors[0]}.${label}.sites.tsv.gz" : "{${donors.join(',')}}.${label}.sites.tsv.gz"
}

process POOLED_LIKELIHOOD_TIERS {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/fa/fa07e248b1e370d7821404c2c9b042d508e30e5147fa2509c4d58f8f103ebaee/data'
        : 'community.wave.seqera.io/library/python_gzip:6ffdc9aac79f425a'}"

    input:
    tuple val(meta), path(calls, stageAs: 'calls/*'), path(extra_counts, stageAs: 'extra/*'), path(sites, stageAs: 'sites/*')
    val sample_map
    val region
    tuple val(annotation_names), path(annotations, stageAs: 'annot/*')

    output:
    tuple val(meta), path(zgTierTables(sample_map, region))                    , emit: sites
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.summary.tsv")         , emit: summary
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.pool_qc.tsv")         , emit: pool_qc
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.run_info.txt")        , emit: run_info
    path "${task.ext.prefix ?: meta.id}.pooled_likelihood_tiers.versions.yml"  , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def donors = sample_map.findAll { row -> row[3] == 'bc1_sample' }.collect { row -> row[1] }.unique()
    if (!donors) {
        error("POOLED_LIKELIHOOD_TIERS ${meta.id}: the sample map has no bc1_sample row")
    }
    if (!(region ==~ /[A-Za-z0-9_.]+(:[0-9]+-[0-9]+)?/)) {
        error("POOLED_LIKELIHOOD_TIERS ${meta.id}: region must be 'chr' or 'chr:start-end', got '${region}'")
    }
    template 'score_pooled_likelihood.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def label  = (region as String).replace(':', '_')
    def donors = sample_map.findAll { row -> row[3] == 'bc1_sample' }.collect { row -> row[1] }.unique().sort()
    def tables = donors.collect { d -> "echo '' | gzip > ${d}.${label}.sites.tsv.gz" }.join('\n    ')
    """
    ${tables}
    touch ${prefix}.summary.tsv ${prefix}.pool_qc.tsv ${prefix}.run_info.txt

    cat <<-END_VERSIONS > ${prefix}.pooled_likelihood_tiers.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
