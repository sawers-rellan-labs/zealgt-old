// MARKER_UNION — stage 5 (PLAN §3 row 5; math supplement Text S5; design §2.4): the union of the tier-A sites of one donor
// set in one region, keyed by (chrom, pos, ref, alt); positions with two ALT alleles are flagged multiallelic and dropped
// downstream. Rewrite of the maths of zealbc1 PHG/bin/union_sites.py (templates/build_marker_union.py, a module template:
// hashed by content).
// Reference donors (run card `reference_donor_tables`, design §2.4): read-only step-4 tables of donors NOT called in this run
// (e.g. the zealbc1 Zx.0570_P2 table for the single-donor Gate 1). Their tier-A sites join the union (donor_kind =
// reference) and their tier `ref` calls are carried per row (ref_donors), so they are a source of gaps and of k / m in the
// step-1 prior; they are never re-called. They are staged by position (stageAs 'reference/?/*') in the order of
// `reference_donors`, so a table's file name does not matter; run-donor tables are matched by name (<donor>.*).
// One run donor and no reference tables: the union is that donor's tier A, n_gaps = 0 in per_donor.tsv, and a
// `WARN ... 0 gap sites` line is logged (no crash, no special case).
// Also writes the non-multiallelic site list of the stage-6 counts (union_sites.tsv), which replaces a separate UNION_SITES
// task. storeDir <store>/genotype/<key>/union (conf/genotype_modules.config), so the versions go into a versions.yml
// (storeDir forbids `eval`). Runs in the shared python env (envs/process_aliases.tsv MARKER_UNION -> pooled_likelihood_tiers).
// ext.args: none.
process MARKER_UNION {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/../pooled_likelihood_tiers/environment.yml"

    input:
    tuple val(meta), path(tables, stageAs: 'step4/*'), path(reference_tables, stageAs: 'reference/?/*')
    val donors
    val reference_donors
    val region

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv.gz")          , emit: union
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.union_sites.tsv") , emit: sites
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.per_donor.tsv")   , emit: per_donor
    path "${task.ext.prefix ?: meta.id}.marker_union.versions.yml"         , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'build_marker_union.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf "" | gzip -n > ${prefix}.tsv.gz
    touch ${prefix}.union_sites.tsv ${prefix}.per_donor.tsv

    cat <<-END_VERSIONS > ${prefix}.marker_union.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
