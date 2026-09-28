// CHROMOSOME_PAINTING — stage 8 (PLAN §3 row 8; design §2.7), one donor x region: one bar per line with the RTIGER segments
// coloured by dosage x (0 = B73, 1 = HET, 2 = donor); positions outside every segment stay white (a no-call is drawn as a
// no-call, not filled from the flanks); lines excluded by LINE_MARKER_QC are drawn grey as "excluded".
// templates/paint_chromosomes.R (module template, hashed by content). Own env (Rscript + data.table + ggplot2). Published
// only (no store), but Nextflow allows `eval` outputs only with bash scripts, so the template writes a versions.yml.
// Inputs: the RTIGER segments CSV (source, donor, name, chr, start_bp, end_bp, state) and line_qc.tsv (optional: []).
// ext.args = --width <inches> (10) --height <inches> (default: by the number of lines).
process CHROMOSOME_PAINTING {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(segments), path(line_qc)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.painting.png"), emit: png
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.painting.pdf"), emit: pdf
    path "${task.ext.prefix ?: meta.id}.chromosome_painting.versions.yml"  , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'paint_chromosomes.R'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.painting.png ${prefix}.painting.pdf

    cat <<-END_VERSIONS > ${prefix}.chromosome_painting.versions.yml
    "${task.process}":
        r-base: 4.4.3
        r-data.table: 1.18.6.1
        r-ggplot2: 4.0.3
    END_VERSIONS
    """
}
