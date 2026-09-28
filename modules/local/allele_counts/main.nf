// ALLELE_COUNTS — per-sample allele depths at fixed sites, the one counting helper of the genotype workflow (PLAN §4 #3;
// genotype design §2.2 "ALLELE_COUNTS"). Included under many names (QC_PANEL_COUNTS, B73_CONTROL_COUNTS, BC1_SITE_COUNTS,
// LINE_ALLELE_COUNTS, UNION_SITE_COUNTS, B73_UNION_COUNTS, LINE_UNION_COUNTS; envs/process_aliases.tsv), always batched:
// one task per donor x region x role or per donor set x region (review #8), never per sample.
//   sites (chrom pos ...; non-numeric pos lines such as a header are skipped) -> pos.tsv (chrom, pos; sorted, unique)
//   bcftools mpileup -I -a AD -f <fasta> -r <region> -T pos.tsv ${args} -b <bams> -Ou
//   | bcftools query -H -f '%CHROM\t%POS\t%REF\t%ALT[\t%AD]\n' | bgzip > <prefix>.ad.tsv.gz
// -I is hard-coded (a correctness requirement: an insertion record at a SNP position would overwrite its counts, PLAN §4 #3);
// ext.args = params.pileup_args ('-q 20 -Q 20 -d 10000'). mpileup's default --ff (UNMAP,SECONDARY,QCFAIL,DUP) drops
// duplicate-flagged reads.
// Output table: the raw `bcftools query -H` header, '#[1]CHROM<TAB>[2]POS<TAB>[3]REF<TAB>[4]ALT<TAB>[5]<sample>:AD ...'
// (bcftools 1.21 may write '# [1]CHROM': parsers strip a leading '#' plus spaces, each '[n]' and the ':AD' suffix), samples
// named by their read-group SM, which MASK_READ_STARTS sets to the sample id. Then one row per covered site: ALT = mpileup's
// observed alleles (may include '<*>'), each sample column = AD, comma-separated in REF,ALT order. Sites without reads have
// no row. Consumers match a site's ALT among the ALT alleles and count a missing allele as 0; they skip indels (none are
// emitted with -I).
// The task checks that the table's sample columns are exactly the input ids (a BAM whose SM differs would silently count
// under another name). An empty site list writes the header only.
// Versions in a versions.yml (bcftools, htslib) so a stub reports the environment.yml pins.
process ALLELE_COUNTS {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(bams, stageAs: 'bam/*'), path(bais, stageAs: 'bam/*'), val(ids)
    tuple val(meta2), path(sites, stageAs: 'sites/*')
    tuple val(meta3), path(fasta), path(fai)
    val region

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.ad.tsv.gz"), emit: counts
    path "${task.ext.prefix ?: meta.id}.allele_counts.versions.yml" , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args ?: ''
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def bam_list = bams instanceof List ? bams : [bams]
    def id_list  = ids instanceof List ? ids : [ids]
    if (bam_list.size() != id_list.size()) {
        error("ALLELE_COUNTS ${prefix}: ${bam_list.size()} BAMs but ${id_list.size()} sample ids")
    }
    if (!id_list.every { id -> id ==~ /[A-Za-z0-9_.-]+/ } || id_list.toUnique().size() != id_list.size()) {
        error("ALLELE_COUNTS ${prefix}: sample ids must be unique and match [A-Za-z0-9_.-]+, got ${id_list}")
    }
    if (!(region ==~ /[A-Za-z0-9_.]+(:[0-9]+-[0-9]+)?/)) {
        error("ALLELE_COUNTS ${prefix}: region must be 'chr' or 'chr:start-end', got '${region}'")
    }
    if (args.tokenize().any { a -> a in ['-r', '--regions', '-R', '--regions-file', '-T', '--targets-file', '-b', '--bam-list', '-O', '--output-type'] }) {
        error("ALLELE_COUNTS ${prefix}: ext.args may not set regions, targets, BAM list or output type (the module does): '${args}'")
    }
    """
    source export_slurm_resources.sh
    set -o pipefail

    printf '%s\\n' ${bam_list.join(' ')} > bams.txt
    printf '%s\\n' ${id_list.join(' ')} | sort > expected_samples.txt
    awk -F '\\t' '\$2 ~ /^[0-9]+\$/ { print \$1 "\\t" \$2 }' ${sites} | sort -k1,1 -k2,2n -u > pos.tsv

    if [ -s pos.tsv ]; then
        bcftools mpileup -I -a AD -f ${fasta} -r ${region} -T pos.tsv ${args} -b bams.txt -Ou \\
        | bcftools query -H -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%AD]\\n' \\
        | bgzip -@ \${ZG_CPUS} > ${prefix}.ad.tsv.gz
    else
        echo "ALLELE_COUNTS ${prefix}: no sites; header only" >&2
        printf '#[1]CHROM\\t[2]POS\\t[3]REF\\t[4]ALT\\t%s\\n' "\$(printf '%s:AD\\n' ${id_list.join(' ')} | awk '{ printf "%s[%d]%s", (NR > 1 ? "\\t" : ""), NR + 4, \$0 }')" | bgzip > ${prefix}.ad.tsv.gz
    fi

    bgzip -dc ${prefix}.ad.tsv.gz | head -1 | cut -f5- | tr '\\t' '\\n' | sed 's/^\\[[0-9]*\\]//; s/:AD\$//' | sort > found_samples.txt
    if ! cmp -s expected_samples.txt found_samples.txt; then
        echo "ALLELE_COUNTS ${prefix}: table samples differ from the input ids (read-group SM vs sample id):" >&2
        diff expected_samples.txt found_samples.txt >&2 || true
        exit 1
    fi
    echo "ALLELE_COUNTS ${prefix}: \$(wc -l < pos.tsv) sites requested, \$(( \$(bgzip -dc ${prefix}.ad.tsv.gz | wc -l) - 1 )) rows, ${id_list.size()} samples" >&2

    cat <<-END_VERSIONS > ${prefix}.allele_counts.versions.yml
    "${task.process}":
        bcftools: \$(bcftools --version | sed '1!d; s/^.*bcftools //')
        htslib: \$(bgzip --version | sed '1!d; s/.* //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the environment.yml pins (the tools are not run in a stub).
    """
    echo '' | gzip > ${prefix}.ad.tsv.gz

    cat <<-END_VERSIONS > ${prefix}.allele_counts.versions.yml
    "${task.process}":
        bcftools: 1.21
        htslib: 1.21
    END_VERSIONS
    """
}
