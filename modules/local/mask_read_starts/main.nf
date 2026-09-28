// MASK_READ_STARTS — Q0 on the first read cycles, before every read consumer (genotype design Decision 6, §2.2;
// agent/20260928_163000_alt_by_read_position.md: batch-1 R1 cycles 1-12 and BC1 cycles 1-2 carry non-genomic bases).
//
// One task per donor x region x role (all the donor's BC1 samples, or all its lines, or the B73 controls; review #8: no
// per-sample tasks). Per sample, one pipe, run for ZG_CPUS samples at a time:
//   samtools view -h -M -L <region.bed> --reference <fasta> <cram> <region>          reads overlapping the region's ranges
//   | gawk <mask>                                                                    QUAL -> '!' on the first N cycles
//   | samtools addreplacerg -m overwrite_all -r '@RG ID:<s> SM:<s>' -O BAM             one RG, SM = sample id
//   then samtools index.
// Mask, in read (sequencing) orientation, soft clips counted as cycles (they are in SEQ; hard clips are not): R1 (flag 0x40)
// gets N = mask_r1, R2 (0x80) N = mask_r2, a read with neither flag N = mask_r1. Forward reads: the first N QUAL characters;
// reverse (0x10): the last N. Secondary / supplementary records (0x900) and records with QUAL '*' pass unchanged.
// Nothing is filtered here (no -q / -F): MAPQ, duplicate and base-quality filters stay in the consumers (mpileup -q20 -Q20,
// CRISP --mmq 20), so `-Q20` and CRISP ignore the masked bases. N = 0 runs the same pipe (mask_read_starts = false).
// The input's @RG header lines are dropped (gawk) before the new RG is added, so every consumer sees exactly one read group
// with SM = the sample id, whatever the input header had (bcftools mpileup names samples by SM; zealbc1-era BC1 CRAMs have
// no @RG; PLAN §4 #1b).
// Inputs: crams / crais in sheet order, ids = sample ids (the output names masked/<id>.bam), masks = [[mask_r1, mask_r2], ...]
// in the same order. <prefix>.masks.tsv records sample, input file, masks and records written.
// Threads: ZG_CPUS parallel samples (bin/export_slurm_resources.sh); versions in a versions.yml (samtools, gawk) so a stub
// reports the environment.yml pins.
process MASK_READ_STARTS {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(crams, stageAs: 'in/*'), path(crais, stageAs: 'in/*'), val(ids), val(masks)
    tuple val(meta2), path(bed)
    tuple val(meta3), path(fasta), path(fai)
    val region

    output:
    tuple val(meta), path("masked/*.bam"), path("masked/*.bam.bai"), emit: bam
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.masks.tsv"), emit: masks
    path "${task.ext.prefix ?: meta.id}.mask_read_starts.versions.yml", emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def cram_list = crams instanceof List ? crams : [crams]
    def id_list   = ids instanceof List ? ids : [ids]
    def mask_list = masks instanceof List && masks.every { m -> m instanceof List } ? masks : [masks]
    if (cram_list.size() != id_list.size() || id_list.size() != mask_list.size()) {
        error("MASK_READ_STARTS ${prefix}: ${cram_list.size()} crams, ${id_list.size()} ids, ${mask_list.size()} masks")
    }
    if (id_list.toUnique().size() != id_list.size()) {
        error("MASK_READ_STARTS ${prefix}: duplicate sample ids ${id_list}")
    }
    if (!(region ==~ /[A-Za-z0-9_.]+(:[0-9]+-[0-9]+)?/)) {
        error("MASK_READ_STARTS ${prefix}: region must be 'chr' or 'chr:start-end', got '${region}'")
    }
    def rows = [cram_list, id_list, mask_list].transpose().collect { row ->
        def (cram, id, mask) = row
        if (!(id ==~ /[A-Za-z0-9_-]+/)) {
            error("MASK_READ_STARTS ${prefix}: sample id '${id}' must match [A-Za-z0-9_-]+ (no dots: CRISP names a pool by its file name up to the first dot)")
        }
        if (!(mask instanceof List) || mask.size() != 2 || !mask.every { v -> (v as String) ==~ /[0-9]+/ && (v as Integer) <= 30 }) {
            error("MASK_READ_STARTS ${prefix}: mask of ${id} must be [mask_r1, mask_r2], integers 0-30, got ${mask}")
        }
        "'${id}' '${cram}' '${mask[0]}' '${mask[1]}'"
    }.join(' ')
    """
    source export_slurm_resources.sh
    set -o pipefail
    mkdir masked

    printf '%s\\t%s\\t%s\\t%s\\n' ${rows} > samples.tsv

    # one sample: region reads -> mask -> one read group -> BAM, then index
    mask_one() {
        local s=\$1 f=\$2 n1=\$3 n2=\$4
        samtools view -h -M -L ${bed} --reference ${fasta} "\$f" ${region} \\
        | gawk -v n1="\$n1" -v n2="\$n2" '
            BEGIN { FS = OFS = "\\t"; bang = ""; for (i = 0; i < 1000; i++) bang = bang "!" }
            /^@/ { if (\$0 !~ /^@RG\\t/) print; next }
            {
                flag = \$2 + 0; q = \$11
                n = and(flag, 128) ? n2 : n1
                if (n > 0 && q != "*" && !and(flag, 2304)) {
                    L = length(q); if (n > L) n = L
                    if (and(flag, 16)) \$11 = substr(q, 1, L - n) substr(bang, 1, n)
                    else \$11 = substr(bang, 1, n) substr(q, n + 1)
                }
                print
            }' \\
        | samtools addreplacerg -m overwrite_all -r "@RG\\tID:\$s\\tSM:\$s" -O BAM -o masked/"\$s".bam - \\
        && samtools index masked/"\$s".bam \\
        && printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "\$s" "\$(basename "\$f")" "\$n1" "\$n2" \\
            "\$(samtools idxstats masked/"\$s".bam | gawk '{ r += \$3 + \$4 } END { print r + 0 }')" > masked/"\$s".row
    }

    pids=""
    n=0
    fail=0
    while IFS=\$'\\t' read -r s f n1 n2; do
        mask_one "\$s" "\$f" "\$n1" "\$n2" &
        pids="\$pids \$!"
        n=\$(( n + 1 ))
        if [ "\$n" -ge "\$ZG_CPUS" ]; then
            for p in \$pids; do wait "\$p" || fail=1; done
            pids=""
            n=0
        fi
    done < samples.tsv
    for p in \$pids; do wait "\$p" || fail=1; done
    [ "\$fail" -eq 0 ] || { echo "MASK_READ_STARTS ${prefix}: a sample pipe failed" >&2; exit 1; }

    printf 'sample\\tinput\\tmask_r1\\tmask_r2\\trecords\\n' > ${prefix}.masks.tsv
    while IFS=\$'\\t' read -r s f n1 n2; do cat masked/"\$s".row; done < samples.tsv >> ${prefix}.masks.tsv
    rm -f masked/*.row

    cat <<-END_VERSIONS > ${prefix}.mask_read_starts.versions.yml
    "${task.process}":
        samtools: \$(samtools version | sed '1!d; s/.* //')
        gawk: \$(gawk --version | sed '1!d; s/GNU Awk //; s/,.*//')
    END_VERSIONS
    """

    stub:
    def prefix  = task.ext.prefix ?: "${meta.id}"
    def id_list = ids instanceof List ? ids : [ids]
    def touches = id_list.collect { id -> "touch masked/${id}.bam masked/${id}.bam.bai" }.join('\n    ')
    // Stub versions are the environment.yml pins (the tools are not run in a stub).
    """
    mkdir masked
    ${touches}
    printf 'sample\\tinput\\tmask_r1\\tmask_r2\\trecords\\n' > ${prefix}.masks.tsv

    cat <<-END_VERSIONS > ${prefix}.mask_read_starts.versions.yml
    "${task.process}":
        samtools: 1.21
        gawk: 5.4.1
    END_VERSIONS
    """
}
