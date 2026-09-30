// RASTERIZE — stage 7 (PLAN §3 row 7; math supplement Eq. S5.1; design §2.6), one donor x region: genotype = RTIGER ancestry
// x donor allele at every non-multiallelic union site: gt = x if D = ALT, 0 if D = REF, NA if D is missing and x > 0, NA
// where the ancestry is unknown or the line was excluded by LINE_MARKER_QC. dosage_expected = x * p_alt (review #9).
// templates/rasterize_genotypes.py (module template, hashed by content). imputation_method = raster; the PHG path is a later
// work package.
// Inputs: DONOR_FOUNDER's table, the RTIGER segments CSV and line_qc.tsv (stage-4 store; line_qc optional: []).
// published to <store>/genotype/<key>/genotypes/<set> (conf/genotype_modules.config) -> versions.yml (a module template: `eval` outputs need a Bash script).
// Own environment.yml (python only). ext.args: none.
process RASTERIZE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(donor_alleles), path(segments), path(line_qc)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tsv.gz")       , emit: genotypes
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.matrix.tsv.gz"), emit: matrix
    path "${task.ext.prefix ?: meta.id}.rasterize.versions.yml"         , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'rasterize_genotypes.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf "" | gzip -n > ${prefix}.tsv.gz
    printf "" | gzip -n > ${prefix}.matrix.tsv.gz

    cat <<-END_VERSIONS > ${prefix}.rasterize.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
