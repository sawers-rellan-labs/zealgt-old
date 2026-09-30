// RTIGER — stage 4 (ancestry_inference) ancestry segments per line (design §2.3; PLAN §3 row 4, §4 #10 decided 2026-09-24:
// run as zealbc1 ran it, own tier-A sites, rigidity 500, parameters learned from the data; zealbc1 PHG/bin/rtiger_poolseq.R):
// nilHMM::call_ancestry(caller = "rtiger") on the LINE_MARKER_QC counts of the lines that passed the coverage floor.
// published to <store>/genotype/<key>/ancestry (conf/genotype_modules.config): <prefix>.segments.csv (source, donor, name, chr,
// start_bp, end_bp, state). With no passing line it writes the header only and a warning (exit 0).
// templates/infer_ancestry_rtiger.R is a module template (hashed by content); nilHMM threads = task.cpus (RcppParallel stays
// at 1 thread, nested threads crashed R). Own image (modules/local/rtiger/Dockerfile: nilHMM v0.3.1 = the code of 248e67e;
// not on conda, so a conda / mamba profile is refused, as nf-core's cellranger). An R template cannot have `eval` outputs, so the versions (R, nilHMM, data.table) go into a versions.yml.
// Inputs besides the counts: the unit's effective rigidity (LINE_MARKER_QC rigidity.txt: params.rigidity scaled to marker
// density), the integer chromosome of the region (nilHMM needs an integer chr;
// e.g. 10 for chr10) and the donor label written into the table (a val, not a custom meta key).
// ext.args = [--seed N] (nilHMM rtiger's randomised init; default 1).
process RTIGER {
    tag "${meta.id}"
    label 'process_medium'

    container "ghcr.io/sawers-rellan-labs/zealgt-nilhmm:0.3.1"    // modules/local/rtiger/Dockerfile (.github/workflows/build_images.yml)

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
    if (workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1) {
        error("RTIGER module does not support Conda (nilHMM is not on conda yet): use the container (Docker / Apptainer / Singularity).")
    }
    template 'infer_ancestry_rtiger.R'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    // Stub versions are the image's pins (modules/local/rtiger/Dockerfile; the tools are not run in a stub).
    """
    touch ${prefix}.segments.csv

    cat <<-END_VERSIONS > ${prefix}.rtiger.versions.yml
    "${task.process}":
        r-base: 4.4.3
        nilhmm: 0.3.1
        r-data.table: 1.18.6.1
    END_VERSIONS
    """
}
