// CRISP — pooled variant discovery on the donor's BC1 pools plus its witness pool (genotype design §2.2; PLAN §3 row 3;
// zealbc1 PHG/bin/donor_discovery_chr10.sbatch step [2]). One task per donor x region.
//   CRISP --bams <list> --ref <fasta> --bed <region.bed> --regions <chrom> --sm 0 ${args} --VCF <prefix>.crisp.vcf
//   then bgzip + tabix.
// ext.args = params.crisp_args ('-p 12 --mmq 20 --filterreads 0 --minc 2': -p = haplotypes per pool, 6 plants x 2).
// --sm 0: CRISP names each pool by its BAM file name up to the first dot (so masked/<sample>.bam and <witness>.bam give the
// sheet's sample ids, which have no dots). The BED is REGION_BED's clipped lowcopy BED; CRISP reads each range end one base
// too far (PLAN §4 #9), which BED_CLIP (bcftools view -T) removes right after this step.
// Input region: 'chr' or 'chr:start-end'; only the chromosome goes to --regions (the BED already holds the region).
// Exit status (design §10.9, to verify on hazel): CRISP exits 1 on success (zealbc1 :40). The task accepts status 0 or 1
// only when the VCF has a #CHROM line and the log has no error line (error / segmentation fault / abort / cannot open /
// failed, any case); anything else fails with CRISP's status, and the status is written to the log's last line.
// CRISP is single-threaded; bgzip uses task.cpus. CRISP has no version option: the version is the commit built by
// build.sh (vibansal/crisp @ 1a9027e), reported as a `versions` topic tuple with htslib's (bgzip, tabix).
process CRISP {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "ghcr.io/sawers-rellan-labs/zealgt-crisp:1a9027e"   // modules/local/crisp/Dockerfile (.github/workflows/build_images.yml)

    input:
    tuple val(meta), path(bams, stageAs: 'bc1/*'), path(bais, stageAs: 'bc1/*'), path(witness_bam, stageAs: 'witness/*'), path(witness_bai, stageAs: 'witness/*')
    tuple val(meta2), path(bed)
    tuple val(meta3), path(fasta), path(fai)
    val region

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.crisp.vcf.gz"), path("${task.ext.prefix ?: meta.id}.crisp.vcf.gz.tbi"), emit: vcf
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.crisp.log")                                                          , emit: log
    tuple val("${task.process}"), val('crisp'), val('1a9027e'), emit: versions_crisp, topic: versions
    tuple val("${task.process}"), val('htslib'), eval("tabix --version | sed '1!d; s/.* //'"), emit: versions_htslib, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args ?: ''
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def crisp_commit = '1a9027e'   // modules/local/crisp/build.sh pin; CRISP prints no version
    def bam_list = (bams instanceof List ? bams : [bams]) + (witness_bam instanceof List ? witness_bam : [witness_bam])
    def names    = bam_list.collect { f -> f.name.tokenize('.')[0] }
    if (names.toUnique().size() != names.size()) {
        error("CRISP ${prefix}: pool names (file name up to the first dot) are not unique: ${names}")
    }
    def chrom = region.tokenize(':')[0]
    """
    set -o pipefail

    printf '%s\\n' ${bam_list.join(' ')} > bams.txt

    set +e
    CRISP --bams bams.txt --ref ${fasta} --bed ${bed} --regions ${chrom} --sm 0 ${args} --VCF ${prefix}.crisp.vcf > ${prefix}.crisp.log 2>&1
    status=\$?
    set -e
    echo "CRISP exit status \$status" >> ${prefix}.crisp.log
    if [ "\$status" -gt 1 ] || ! grep -q '^#CHROM' ${prefix}.crisp.vcf 2>/dev/null \\
        || grep -qiE 'error|segmentation fault|abort|cannot open|failed' ${prefix}.crisp.log; then
        echo "CRISP ${prefix}: failed (status \$status); log tail:" >&2
        tail -20 ${prefix}.crisp.log >&2
        exit \$(( status > 1 ? status : 1 ))
    fi
    echo "CRISP ${prefix}: \$(grep -vc '^#' ${prefix}.crisp.vcf || true) records, status \$status" >&2

    bgzip -@ ${task.cpus} -f ${prefix}.crisp.vcf
    tabix -f -p vcf ${prefix}.crisp.vcf.gz

    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '' | gzip > ${prefix}.crisp.vcf.gz
    touch ${prefix}.crisp.vcf.gz.tbi ${prefix}.crisp.log

    """
}
