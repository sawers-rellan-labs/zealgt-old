// RTIGER — stage 4 (ancestry_inference) ancestry segments per line (design §2.3; PLAN §3 row 4, §4 #10 decided 2026-09-24:
// run as zealbc1 ran it, own tier-A sites, rigidity 500, parameters learned from the data; zealbc1 PHG/bin/rtiger_poolseq.R):
// nilHMM::call_ancestry(caller = "rtiger") on the LINE_MARKER_QC counts of the lines that passed the coverage floor.
// storeDir <store>/genotype/<key>/ancestry (conf/genotype_modules.config): <prefix>.segments.csv (source, donor, name, chr,
// start_bp, end_bp, state). With no passing line it writes the header only and a warning (exit 0).
// templates/infer_ancestry_rtiger.R is a module template (hashed by content); it runs bin/export_slurm_resources.sh for
// ZG_CPUS (nilHMM threads; RcppParallel stays at 1 thread, nested threads crashed R). Own env (modules/local/rtiger/environment.yml + build.sh: nilHMM
// 0.3.0 @ 248e67e). storeDir forbids `eval` outputs, so the versions (R, nilHMM, data.table) go into a versions.yml.
// Inputs besides the counts: rigidity (params.rigidity), the integer chromosome of the region (nilHMM needs an integer chr;
// e.g. 10 for chr10) and the donor label written into the table (a val, not a custom meta key).
// ext.args = [--seed N] (nilHMM rtiger's randomised init; default 1).
process RTIGER {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    input:
    tuple val(meta), path(counts)
    val rigidity
    val chrom_int
    val donor

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.segments.csv"), emit: segments
    path "${task.ext.prefix ?: meta.id}.rtiger.versions.yml"            , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'infer_ancestry_rtiger.R'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the environment.yml / build.sh pins (the tools are not run in a stub).
    """
    touch ${prefix}.segments.csv

    cat <<-END_VERSIONS > ${prefix}.rtiger.versions.yml
    "${task.process}":
        r-base: 4.4.3
        nilhmm: 0.3.0
        r-data.table: 1.18.6.1
    END_VERSIONS
    """
}
