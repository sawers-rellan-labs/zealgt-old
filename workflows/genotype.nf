/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Genotype workflow: CRAM store + sample sheet + run card -> discovery, union, ancestry, gap filling, genotypes,
    reporting (docs/PLAN_pipeline.md §3 rows 2b-8). SKELETON ONLY (Phase B, 2026-09-28): the entry exists so the
    --workflow dispatcher is complete; no stage is implemented yet, so it stops with a clear message.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOTYPE {

    main:
    error("--workflow genotype is not implemented yet (skeleton; PLAN §3 rows 2b-8: sample_quality_control, variant_discovery, ancestry_inference, marker_union, donor_allele_calling, genotype_imputation, reporting)")
}
