// MIN_COVERAGE — stage 2b (sample_quality_control), the minimum-coverage rule (PLAN §3 row 2b; decided 2026-09-27): a sample
// whose Picard CollectWgsMetrics MEAN_COVERAGE (after duplicate marking) is below `min_coverage` (0.05x) is excluded from all
// genotype processing. One task per cohort (the sheet rows of --donors plus the B73 controls): reads each sample's
// <sample>.CollectWgsMetrics.coverage_metrics from the CRAM store and writes one row per sample (templates/flag_low_coverage.py,
// a module template: hashed by content). A sample without a metrics file or without MEAN_COVERAGE fails with that reason.
// Own environment.yml (python only). The python version goes into a versions.yml (a module template: `eval` outputs need a Bash script).
process MIN_COVERAGE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ea/eab5e327131db0b3743e8264de7ea497bf3f9d2d5c4bab89147c89c0bb7cb765/data'
        : 'community.wave.seqera.io/library/python:3.12.14--e1a45735c4c986d6'}"

    input:
    tuple val(meta), path(metrics, stageAs: 'metrics/*'), val(sample_ids)
    val min_coverage

    output:
    tuple val(meta), path("${task.ext.prefix ?: meta.id}.min_coverage.tsv"), emit: tsv
    path "${task.ext.prefix ?: meta.id}.min_coverage.versions.yml"          , emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    template 'flag_low_coverage.py'

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.min_coverage.tsv

    cat <<-END_VERSIONS > ${prefix}.min_coverage.versions.yml
    "${task.process}":
        python: 3.12.14
    END_VERSIONS
    """
}
