// WITNESS_POOL — the donor's BC2S3 lines merged into one pool with one read group (genotype design §2.2; PLAN §3 row 3;
// zealbc1 PHG/bin/donor_discovery_chr10.sbatch step [1]). One task per donor x region, on the masked, region-limited line
// BAMs of MASK_READ_STARTS.
//   samtools merge -u - <bams> | samtools addreplacerg -m overwrite_all -r '@RG ID:<w> SM:<w> PL:ILLUMINA' -> <w>.bam, index
// One pipe (PLAN §2 principle 5): the merged intermediate never reaches work/. The output is named <witness>.bam because
// CRISP (--sm 0) names a pool by its file name up to the first dot, so witness must match [A-Za-z0-9_-]+ (the design's
// donor.replace('.', '') + '_BC2S3', zealbc1 :24). The task checks that the pool's header holds exactly that one @RG
// (CRISP splits a file by read group, PLAN §4 #1b); a samtools that kept the inputs' @RG lines would fail here, not later.
// Duplicates are not re-marked: every record keeps its per-sample duplicate flag (merged pools are not deduplicated, §4 #1b).
// Threads from bin/export_slurm_resources.sh; versions in a versions.yml (samtools) so a stub reports the pin.
process WITNESS_POOL {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(bams, stageAs: 'in/*'), path(bais, stageAs: 'in/*'), val(witness)
    tuple val(meta2), path(fasta), path(fai)

    output:
    tuple val(meta), path("${witness}.bam"), path("${witness}.bam.bai"), emit: bam
    path "${task.ext.prefix ?: meta.id}.witness_pool.versions.yml"    , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def bam_list = bams instanceof List ? bams : [bams]
    if (!(witness ==~ /[A-Za-z0-9_-]+/)) {
        error("WITNESS_POOL ${prefix}: witness name '${witness}' must match [A-Za-z0-9_-]+ (no dots: CRISP --sm 0 cuts the file name at the first dot)")
    }
    if (bam_list.any { f -> f.name == "${witness}.bam" }) {
        error("WITNESS_POOL ${prefix}: an input is already named ${witness}.bam")
    }
    """
    source export_slurm_resources.sh
    set -o pipefail

    samtools merge -@ \${ZG_CPUS} -u ${args} -o - ${bam_list.join(' ')} \\
    | samtools addreplacerg -@ \${ZG_CPUS} -m overwrite_all -r '@RG\\tID:${witness}\\tSM:${witness}\\tPL:ILLUMINA' \\
        --reference ${fasta} -O BAM -o ${witness}.bam -
    samtools index -@ \${ZG_CPUS} ${witness}.bam

    n_rg=\$(samtools view -H ${witness}.bam | grep -c '^@RG' || true)
    rg=\$(samtools view -H ${witness}.bam | grep '^@RG' || true)
    case "\$rg" in
        *\$'\\t'ID:${witness}\$'\\t'*) ;;
        *) n_rg=0 ;;
    esac
    [ "\$n_rg" -eq 1 ] || { echo "WITNESS_POOL ${prefix}: ${witness}.bam header has \$n_rg matching @RG lines, expected exactly one (ID:${witness})" >&2; exit 1; }
    echo "WITNESS_POOL ${prefix}: ${bam_list.size()} BAMs -> ${witness}.bam, \$(samtools idxstats ${witness}.bam | awk '{ r += \$3 + \$4 } END { print r + 0 }') records" >&2

    cat <<-END_VERSIONS > ${prefix}.witness_pool.versions.yml
    "${task.process}":
        samtools: \$(samtools version | sed '1!d; s/.* //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub version is the environment.yml pin (samtools is not run in a stub).
    """
    touch ${witness}.bam ${witness}.bam.bai

    cat <<-END_VERSIONS > ${prefix}.witness_pool.versions.yml
    "${task.process}":
        samtools: 1.21
    END_VERSIONS
    """
}
