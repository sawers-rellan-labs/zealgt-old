// WITNESS_VETO — keep a CRISP record only if the witness pool (the donor's merged BC2S3 lines) shows the ALT allele
// (genotype design §2.2; math supplement "Witness veto"; PLAN §4 #5; zealbc1 PHG/bin/veto_witness.py). One task per donor x
// region, on BED_CLIP's in-range VCF.
// Rule: witness ALT reads = sum over CRISP's ADf, ADr, ADb of every ALT allele's count; keep when >= --min-alt-reads
// (ext.args, params.veto_min_alt_reads, default 1: a presence test, finding 4 withdrawn). Every record type is vetoed the
// same way; the SNP-only restriction is POOLED_LIKELIHOOD_TIERS's.
// Outputs: <prefix>.vetoed.vcf.gz (BGZF-compressed, so tabix / bcftools read it; written by the standard-library template),
// <prefix>.kept_sites.tsv (chrom pos ref alt of the kept records, no header: the site list of B73_CONTROL_COUNTS),
// <prefix>.veto_summary.tsv.
// Own environment.yml (python only). Template templates/veto_by_witness.py writes the versions.yml.
process WITNESS_VETO {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

    input:
    tuple val(meta), path(vcf, stageAs: 'input/*')
    val witness

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.vetoed.vcf.gz")    , emit: vcf
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.kept_sites.tsv")   , emit: sites
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.veto_summary.tsv") , emit: summary
    path "${task.ext.prefix ?: meta.id}.witness_veto.versions.yml"          , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    if (!(witness ==~ /[A-Za-z0-9_-]+/)) {
        error("WITNESS_VETO ${meta.id}: witness name '${witness}' must match [A-Za-z0-9_-]+")
    }
    template 'veto_by_witness.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '' | gzip > ${prefix}.vetoed.vcf.gz
    touch ${prefix}.kept_sites.tsv ${prefix}.veto_summary.tsv

    cat <<-END_VERSIONS > ${prefix}.witness_veto.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
