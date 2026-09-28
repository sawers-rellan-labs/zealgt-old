#!/usr/bin/env bash
# REAL local runs (laptop, tools from agent/localbin, conda off) after the refactor: --entry read_demultiplexing on the
# fixture library (-profile test), then markdup_import on three CRAMs derived from its output (RG stripped / header RG kept /
# two RGs). Checks the python templates, the helper sourced by name from bin/ and the staged Trimmomatic adapters for real.
# Usage: bash <this> [demux|import|all]
A=/Users/fvrodriguez/repos/zealgt/agent
R=/Users/fvrodriguez/repos/zealgt
export PATH="$A/bin:$A/localbin:$PATH" NXF_VER=26.04.6 NXF_ANSI_LOG=false
RUN=$A/20260928_221500_localrun_real; mkdir -p "$RUN"; cd "$RUN" || exit 1
FA="$R/tests/fixtures/ref/tiny.fa"
common=(-profile test -c "$A/20260928_055000_local_real.config" --store "$RUN/store")
step="${1:-all}"
if [ "$step" = all ] || [ "$step" = demux ]; then
    echo "===== read_demultiplexing (real)"
    nextflow run "$R" "${common[@]}" --outdir "$RUN/results_demux" 2>&1 | grep -E "ERROR|SUCCESS|FAILED|PROCESS|Error|WARN" | head -40
fi
if [ "$step" = all ] || [ "$step" = import ]; then
    echo "===== markdup_import (real)"
    mkdir -p imp
    samtools view -h "$RUN/store/cram/LX_1.cram" --reference "$FA" | grep -v '^@RG' | sed 's/\tRG:Z:[^\t]*//' | samtools view -C -T "$FA" -o imp/OLD_1.cram - && samtools index imp/OLD_1.cram
    samtools view -C -T "$FA" -o imp/OLD_2.cram "$RUN/store/cram/LX_2.cram" && samtools index imp/OLD_2.cram
    samtools merge -f --reference "$FA" -O cram -o imp/OLD_3.cram "$RUN/store/cram/LX_1.cram" "$RUN/store/cram/LX_3.cram" && samtools index imp/OLD_3.cram
    {
        echo "sample_id,source,role,library,donor,import_set,path,index,size_bytes,made_by,dup_marked,read_groups,include,note"
        echo "OLD_1,bc1,bc1_sample,LIBX,Zx.TEST_P1,testset,$RUN/imp/OLD_1.cram,$RUN/imp/OLD_1.cram.crai,1,test,no,no,TRUE,rg stripped"
        echo "LX_2,bc1,bc1_sample,LIBX,Zx.TEST_P1,testset,$RUN/imp/OLD_2.cram,$RUN/imp/OLD_2.cram.crai,1,test,no,no,TRUE,header rg kept"
        echo "OLD_3,b73_control,b73_control,,,b73_control,$RUN/imp/OLD_3.cram,$RUN/imp/OLD_3.cram.crai,1,test merge,no,check,TRUE,two RGs"
    } > import.csv
    nextflow run "$R" "${common[@]}" --entry markdup_import --import_sheet "$RUN/import.csv" --outdir "$RUN/results_import" 2>&1 | grep -E "ERROR|SUCCESS|FAILED|PROCESS|Error" | head -40
fi
