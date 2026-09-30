// READ_POSITION_QC — stage 8 (design §2.7; the standing form of agent/20260928_163000_alt_by_read_position.md): REF / ALT /
// other base fractions at known sites (the donor's own tier-A sites) by read cycle bin (5' end, sequencing orientation,
// clipped bases counted), per sample and for the role group, R1 and R2. `label` names what was counted (raw = the stored
// CRAMs, masked = MASK_READ_STARTS output), so a raw and a masked run give the before/after view of the 5' mask. Run when
// the `read_position_qc` param is true.
// templates/count_alt_by_cycle.py (module template, hashed by content): `samtools view ${ext.args} -M -L <sites>.bed`
// piped per sample into the counter; samples in parallel over task.cpus (conf/genotype_hazel.config). Own env
// (samtools + python). Published only (no store), but Nextflow allows `eval` outputs only with bash scripts, so the template
// writes a versions.yml (samtools, python).
// Alignments are matched to `sample_ids` by name (<sample>.bam or <sample>.cram); indexes staged next to them.
// ext.args = samtools view filters (-q 20 -F 0xF04); ext.args2 = counter options --min-bq (20) --bins
// (1-2,3-4,5-8,9-12,13-20,21-40,41-80,81-).
process READ_POSITION_QC {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(alignments, stageAs: 'aln/*'), path(indexes, stageAs: 'aln/*'), val(sample_ids)
    tuple val(meta2), path(sites)
    tuple val(meta3), path(fasta), path(fai)
    val region
    val label

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.read_position_qc.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.read_position_qc.versions.yml"         , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'count_alt_by_cycle.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.read_position_qc.tsv

    cat <<-END_VERSIONS > ${prefix}.read_position_qc.versions.yml
    "${task.process}":
        samtools: 1.21
        python: 3.12.14
    END_VERSIONS
    """
}
