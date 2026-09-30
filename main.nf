#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    sawers-rellan-labs/zealgt
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Github : https://github.com/sawers-rellan-labs/zealgt
----------------------------------------------------------------------------------------
    Two workflows named by their endpoints (docs/PLAN_pipeline.md §3), chosen by the schema-validated --workflow param:
      --workflow cram      raw libraries -> analysis-ready CRAMs + QC + provenance + demux registry (workflows/cram.nf);
                           the entry is chosen by --entry (read_demultiplexing: stage 1 -> FASTQ checkpoint -> stage 2 |
                           read_alignment: stage 2 from the checkpoint | markdup_import)
      --workflow genotype  CRAM store -> sample QC, discovery, ancestry, union, donor alleles, genotypes, reports
                           (workflows/genotype.nf); --entry <stage> runs that stage only (sample_quality_control |
                           variant_discovery | ancestry_inference | marker_union | donor_allele_calling |
                           genotype_imputation | reporting), reading --cram_store and writing <store>/genotype/<genotype_store_key>
    The store is the only contract between them.
----------------------------------------------------------------------------------------
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS / WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CRAM                    } from './workflows/cram'
include { GENOTYPE                } from './workflows/genotype'
include { PIPELINE_INITIALISATION } from './subworkflows/local/utils_nfcore_zealgt_pipeline'
include { PIPELINE_COMPLETION     } from './subworkflows/local/utils_nfcore_zealgt_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOWS FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// WORKFLOW: dispatch to the CRAM or the genotype workflow
//
workflow SAWERSRELLANLABS_ZEALGT {

    take:
    ch_libraries // channel: [ val(lmeta), [ raw R1 ], [ raw R2 ], val(barcodes), val(read_structures), val(tar_members) ]
    ch_checkpoint // channel: [ val(meta), val(checkpoint row) ]
    ch_imports   // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]
    ch_records   // channel: [ val(sample_id), val(provenance record) ]
    ch_genotype_samples // channel: [ val(meta), cram, crai, metrics, val([mask_r1, mask_r2]) ]

    main:
    def ch_multiqc_report = channel.empty()
    def ch_task_dirs = channel.empty()
    if (params.workflow == 'cram') {
        CRAM (
            ch_libraries,
            ch_checkpoint,
            ch_imports,
            ch_records,
            params.multiqc_config,
            params.multiqc_logo,
            params.outdir,
        )
        ch_multiqc_report = CRAM.out.multiqc_report
        ch_task_dirs = CRAM.out.task_dirs
    }
    else if (params.workflow == 'genotype') {
        GENOTYPE (
            ch_genotype_samples,
        )
    }
    else {
        error("unknown --workflow '${params.workflow}' (cram | genotype)")
    }

    emit:
    multiqc_report = ch_multiqc_report // channel: /path/to/multiqc_report.html
    task_dirs      = ch_task_dirs      // channel: [ library, process, task work dir ]  stage-1 tasks (cleanup report)
}
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {

    main:
    //
    // SUBWORKFLOW: Run initialisation tasks (schema validation, run guards, entry inputs from the sample sheets)
    //
    PIPELINE_INITIALISATION (
        params.version,
        params.validate_params,
        params.monochrome_logs,
        args,
        params.outdir,
        params.help,
        params.help_full,
        params.show_hidden
    )

    //
    // WORKFLOW: Run main workflow
    //
    SAWERSRELLANLABS_ZEALGT (
        PIPELINE_INITIALISATION.out.libraries,
        PIPELINE_INITIALISATION.out.checkpoint,
        PIPELINE_INITIALISATION.out.imports,
        PIPELINE_INITIALISATION.out.records,
        PIPELINE_INITIALISATION.out.genotype_samples,
    )

    //
    // SUBWORKFLOW: Run completion tasks
    //
    PIPELINE_COMPLETION (
        params.monochrome_logs,
        SAWERSRELLANLABS_ZEALGT.out.task_dirs,
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
