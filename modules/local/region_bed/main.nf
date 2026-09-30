// REGION_BED — clip the lowcopy BED to one region (genotype design §2.2; one task per region, shared by every donor unit).
//
// Input region: 'chr' (whole chromosome) or 'chr:start-end' (1-based, inclusive). Output <label>.bed keeps the BED
// convention (0-based, half-open) and ends in `.bed`, so `bcftools -T` and CRISP `--bed` read it as BED; overlapping or
// abutting ranges are merged, ranges are sorted by position. <label>.regions.txt lists the same ranges as 1-based
// `chr:start-end` strings (samtools / bcftools region syntax). A region that keeps no range stops the task (no silent
// empty unit), unless ext.args has --allow-empty.
// Own environment.yml (python only). Python standard library only (templates/clip_bed_to_region.py).
// Version: one versions.yml written by the template (house python modules; a stub reports the pinned python).
process REGION_BED {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(bed, stageAs: 'input/*')
    val region

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.bed")        , emit: bed
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.regions.txt"), emit: regions
    path "${task.ext.prefix ?: meta.id}.region_bed.versions.yml"      , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    if (!(region ==~ /[A-Za-z0-9_.]+(:[0-9]+-[0-9]+)?/)) {
        error("REGION_BED ${meta.id}: region must be 'chr' or 'chr:start-end', got '${region}'")
    }
    template 'clip_bed_to_region.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bed ${prefix}.regions.txt

    cat <<-END_VERSIONS > ${prefix}.region_bed.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
