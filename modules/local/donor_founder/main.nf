// DONOR_FOUNDER — stage 6, the final donor allele D (ALT / REF / NA) at every union site of one donor x region (PLAN §3
// row 6; design §2.5): own tier A -> ALT; step 1 REF / ALT; step 1 missing + step 2 ALT -> ALT; else NA; multiallelic
// positions NA. call_step records which step decided (own, step1_ref, step1_alt, step2_alt, missing, multiallelic), and the
// summary gives the step-1 and step-2 shares of the gaps separately (review #2). logodds / p_alt carry the evidence for
// RASTERIZE's dosage_expected (review #9). templates/call_donor_founder.py (module template, hashed by content).
// Inputs: the set's GAP_FILLING_BC1 table (the donor's rows are picked by `donor`), the donor's GAP_FILLING_LINES table and
// the union (MARKER_UNION).
// published to <store>/genotype/<key>/donor_alleles/<set> (conf/genotype_modules.config) -> versions.yml (a module template: `eval` outputs need a Bash script). Own environment.yml (python only). ext.args: none.
process DONOR_FOUNDER {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

    input:
    tuple val(meta), path(gap_bc1), path(gap_lines), path(union)
    val donor

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv.gz")     , emit: alleles
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.summary.tsv"), emit: summary
    path "${task.ext.prefix ?: meta.id}.donor_founder.versions.yml"   , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'call_donor_founder.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf "" | gzip -n > ${prefix}.tsv.gz
    touch ${prefix}.summary.tsv

    cat <<-END_VERSIONS > ${prefix}.donor_founder.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
