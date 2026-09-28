#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    sawers-rellan-labs/zealgt
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Github : https://github.com/sawers-rellan-labs/zealgt
----------------------------------------------------------------------------------------
    Two workflows named by their endpoints (docs/PLAN_pipeline.md §3), chosen by the schema-validated --workflow param:
      --workflow cram      raw libraries -> analysis-ready CRAMs + QC + provenance + demux registry (workflows/cram.nf);
                           the entry is chosen by --entry (read_demultiplexing | markdup_import)
      --workflow genotype  CRAM store -> discovery ... genotypes (workflows/genotype.nf; skeleton, not implemented yet)
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
    ch_samples   // channel: [ val(meta), val(read_group) ]
    ch_imports   // channel: [ val(meta), cram|bam, crai|bai, val(read_group) ]
    ch_records   // channel: [ val(sample_id), val(provenance record) ]

    main:
    def ch_multiqc_report = channel.empty()
    if (params.workflow == 'cram') {
        CRAM (
            ch_libraries,
            ch_samples,
            ch_imports,
            ch_records,
            params.multiqc_config,
            params.multiqc_logo,
            params.outdir,
        )
        ch_multiqc_report = CRAM.out.multiqc_report
    }
    else if (params.workflow == 'genotype') {
        GENOTYPE ()
    }
    else {
        error("unknown --workflow '${params.workflow}' (cram | genotype)")
    }

    emit:
    multiqc_report = ch_multiqc_report // channel: /path/to/multiqc_report.html
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
        PIPELINE_INITIALISATION.out.samples,
        PIPELINE_INITIALISATION.out.imports,
        PIPELINE_INITIALISATION.out.records,
    )

    //
    // SUBWORKFLOW: Run completion tasks
    //
    PIPELINE_COMPLETION (
        params.monochrome_logs,
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
