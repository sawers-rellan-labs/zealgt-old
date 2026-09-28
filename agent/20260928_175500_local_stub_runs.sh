#!/usr/bin/env bash
# Local -stub runs (laptop) of both CRAM entries after the refactor: read_demultiplexing (-profile test,stub) and
# markdup_import on a generated import sheet (touch-file CRAMs). Usage: bash <this> [demux|import|all]
A=/Users/fvrodriguez/repos/zealgt/agent
R=/Users/fvrodriguez/repos/zealgt
chmod +x "$A/stubbin/cutadapt" "$A/stubbin/pigz"
export PATH="$A/bin:$A/stubbin:$PATH" NXF_VER=26.04.6 NXF_ANSI_LOG=false
RUN=$A/20260928_175500_localrun_stub2; mkdir -p "$RUN"; cd "$RUN" || exit 1
step="${1:-all}"
if [ "$step" = all ] || [ "$step" = demux ]; then
    echo "===== read_demultiplexing (test,stub)"
    nextflow run "$R" -profile test,stub -stub --outdir "$RUN/results_demux" 2>&1 | tail -40
fi
if [ "$step" = all ] || [ "$step" = import ]; then
    echo "===== markdup_import (test,stub)"
    mkdir -p imp
    for s in IMP_A IMP_B IMP_C; do touch imp/$s.cram imp/$s.cram.crai; done
    {
        echo "sample_id,source,role,library,donor,import_set,path,index,size_bytes,made_by,dup_marked,read_groups,include,note"
        echo "IMP_A,bc1,bc1_sample,2A,Zx.0540_P3,Zx.0540_P3,$RUN/imp/IMP_A.cram,$RUN/imp/IMP_A.cram.crai,10,nilhmm pool_run (ALIGN),no,no,TRUE,"
        echo "IMP_B,bc2s3_batch1,line,BZea5,Zx.0540_P3,Zx.0540_P3,$RUN/imp/IMP_B.cram,$RUN/imp/IMP_B.cram.crai,10,zealbc1 bc2s3_realign,no,no,TRUE,"
        echo "IMP_C,b73_control,b73_control,,,b73_control,$RUN/imp/IMP_C.cram,$RUN/imp/IMP_C.cram.crai,10,zealbc1 align_b73,no,check,FALSE,excluded"
    } > import.csv
    nextflow run "$R" -profile test,stub -stub --entry markdup_import --import_sheet "$RUN/import.csv" --outdir "$RUN/results_import" 2>&1 | tail -30
fi
find "$RUN"/results_* -path '*store_stub*' -type f | sort | sed "s#$RUN/##"
