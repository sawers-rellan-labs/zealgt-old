// RTIGER_MARKERS — stage 4 (ancestry_inference) marker list (design §2.3; zealbc1 PHG/bin/rtiger_ancestry_inference.sbatch):
// the donor's own tier-A sites from its step-4 table (POOLED_LIKELIHOOD_TIERS, <donor>.<region>.sites.tsv.gz): tier A,
// biallelic single-base SNVs, no hard flag; a position with two kept alleles is dropped. Writes the header-less site list
// (chrom pos ref alt) that LINE_ALLELE_COUNTS (ALLELE_COUNTS alias) counts the lines at and LINE_MARKER_QC matches alleles
// with, plus a one-row summary (templates/select_rtiger_markers.py, a module template: hashed by content). Does not depend on
// the union (PLAN §3 row 4). Own environment.yml (python only).
// ext.args = [--tier A --exclude-flags hidepth,af_gt_half,inconsistent].
process RTIGER_MARKERS {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

    input:
    tuple val(meta), path(sites)

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.tierA_sites.tsv")  , emit: sites
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.rtiger_markers.tsv"), emit: summary
    path "${task.ext.prefix ?: meta.id}.rtiger_markers.versions.yml"         , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'select_rtiger_markers.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.tierA_sites.tsv ${prefix}.rtiger_markers.tsv

    cat <<-END_VERSIONS > ${prefix}.rtiger_markers.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
