// SAMPLE_LABELS — stage 8, first reporting task of one donor x region: the edge translation of meta/PROVENANCE.md
// "Identifiers: one physical key, biology in the registry". Internal tables are keyed by the well-level sample_id; this task
// joins them ONCE on the current registry (meta/registry.csv, resolved columns = meta/corrections.csv applied) and writes the
// final genotype tables (long + matrix), the exclusion table and the segments / line_qc that GENOTYPE_SUMMARY and
// CHROMOSOME_PAINTING read with the short label: nil_id_resolved, else pedigree_resolved (line id), else the sample_id (B73
// controls have no registry row; a row with exclude = TRUE is refused). Replicate wells that share a
// nil_id are suffixed _<sample_id> and listed in <unit>.sample_labels.tsv, which also records the registry path, sha256 and
// the repo commit (code_version). The registry is recorded, not part of the settings guard.
// templates/label_samples.py (module template, hashed by content). Published only (no store), but Nextflow allows `eval`
// outputs only with bash scripts, so the template writes a versions.yml. Shared python env (envs/process_aliases.tsv
// SAMPLE_LABELS -> pooled_likelihood_tiers). Inputs are staged under input/ (the outputs reuse the store file names).
// donor = the unit donor (a registry donor that differs is refused); sample_ids = the unit's sheet samples (listed in the
// labels table even when absent from the tables, e.g. the B73 controls); registry_source = the registry path as recorded.
// ext.args: none.
process SAMPLE_LABELS {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/../pooled_likelihood_tiers/environment.yml"

    input:
    tuple val(meta), path(genotypes, stageAs: 'input/*'), path(matrix, stageAs: 'input/*'), path(segments, stageAs: 'input/*'), path(line_qc, stageAs: 'input/*'), path(exclusions, stageAs: 'input/*'), val(donor), val(sample_ids)
    path registry
    val registry_source
    val code_version

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.genotypes.tsv.gz")       , emit: genotypes
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.genotypes.matrix.tsv.gz"), emit: matrix
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.segments.csv")           , emit: segments
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.line_qc.tsv")            , emit: line_qc
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.exclusions.tsv")         , emit: exclusions
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.sample_labels.tsv")      , emit: labels
    path "${task.ext.prefix ?: meta.id}.sample_labels.versions.yml"               , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'label_samples.py'

    stub:
    // the inputs are copied unchanged (sample_id labels), so the stub reporting tasks see the same tables
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    cp ${genotypes} ${prefix}.genotypes.tsv.gz
    cp ${matrix} ${prefix}.genotypes.matrix.tsv.gz
    cp ${segments} ${prefix}.segments.csv
    cp ${line_qc} ${prefix}.line_qc.tsv
    cp ${exclusions} ${prefix}.exclusions.tsv
    printf 'sample_id\\tlabel\\tlabel_source\\tcollision\\tnil_id\\tpedigree\\tdonor\\ttaxon\\trole\\tcorrection_ids\\tregistry\\tregistry_sha256\\tcode_version\\n' > ${prefix}.sample_labels.tsv

    cat <<-END_VERSIONS > ${prefix}.sample_labels.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
