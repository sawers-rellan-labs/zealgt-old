// LINE_MARKER_QC — stage 4 (ancestry_inference) coverage floor and RTIGER input (design §2.3; PLAN §4 #13 decided
// 2026-09-24): from the LINE_ALLELE_COUNTS table of the donor's lines at its own tier-A markers (RTIGER_MARKERS), per line
// REF / ALT reads at each marker; markers with 0 ALT reads over all lines dropped (--drop-invariant, as zealbc1); a line
// with any contig below ceil(min_markers_factor x rigidity) covered markers (>= 1 read; never below RTIGER's own 2 x
// rigidity) is excluded, here and in every later caller (they read line_qc.tsv). rigidity is the effective one: with
// rigidity_ref_markers > 0 the rigidity input is its value at that many markers per chromosome, scaled to the unit's kept
// markers per chromosome (chromosome length from the .fai, region = the unit's interval); it is written to
// <prefix>.rigidity.txt and is RTIGER's rigidity for the unit (user rule 2026-09-29). Writes the RTIGER counts table of the
// passing lines and the per-line QC table (templates/filter_line_markers.py, a module template: hashed by content). The
// markers input is needed to pick each marker's ALT among mpileup's AD alleles (zealbc1 ad_to_counts.py read it too).
// Own environment.yml (python only).
// ext.args = --drop-invariant true|false (params.rtiger_drop_invariant_sites).
process LINE_MARKER_QC {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(counts), path(sites)
    val rigidity
    val min_markers_factor
    val rigidity_ref_markers
    path fai
    val region

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.counts.tsv")  , emit: counts
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.line_qc.tsv") , emit: line_qc
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.rigidity.txt"), emit: rigidity
    path "${task.ext.prefix ?: meta.id}.line_marker_qc.versions.yml"   , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'filter_line_markers.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.counts.tsv ${prefix}.line_qc.tsv
    echo ${rigidity} > ${prefix}.rigidity.txt

    cat <<-END_VERSIONS > ${prefix}.line_marker_qc.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
