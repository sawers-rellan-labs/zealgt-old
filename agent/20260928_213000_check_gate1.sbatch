#!/bin/bash
#SBATCH --job-name=zg_gate1_check
#SBATCH --account=maize_cpu
#SBATCH --partition=compute_partners
#SBATCH --qos=short
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --output=/share/maize/frodrig4/nf_work/gate1_check_%j.log
# Gate 1 output checks (read-only). Submitted as `ssh hazel 'sbatch' < agent/20260928_213000_check_gate1.sbatch`.
ZEAL=/rsstu/users/r/rrellan/BZea/ZEAL
W=/share/maize/frodrig4/nf_work
REF=$ZEAL/reference/B73.fa
SAM=/share/maize/frodrig4/conda/zealgt/align_markdup-1bd0900b/bin/samtools
S1=$ZEAL/store/subsample_1000000
SI=$ZEAL/store_gate1
O1=$ZEAL/results/zealgt/gate1_1A
OI=$ZEAL/results/zealgt/gate1_import

echo "##### DEMUX_QC summary"; cat $S1/demux_qc/1A.summary.tsv
echo "##### DEMUX_QC per sample"; cat $S1/demux_qc/1A.tsv
echo "##### read start: max base share at positions 1-4 per sample x read, and TruSeq read-through share"
awk -F'\t' 'NR>1 && $5<=4 { m=$6; b="A"; if($7>m){m=$7;b="C"} if($8>m){m=$8;b="G"} if($9>m){m=$9;b="T"}
    printf "%s %s pos%s top=%s %.3f  A=%s C=%s G=%s T=%s N=%s  readthrough=%s n=%s\n", $2,$3,$5,b,m,$6,$7,$8,$9,$10,$11,$4 }' $S1/demux_qc/1A.read_start.tsv
echo "##### read start: library-wide mean composition per read x position (1-10)"
awk -F'\t' 'NR>1 { k=$3" "$5; a[k]+=$6; c[k]+=$7; g[k]+=$8; t[k]+=$9; n[k]++ } END { for (k in a) printf "%s A=%.3f C=%.3f G=%.3f T=%.3f\n", k, a[k]/n[k], c[k]/n[k], g[k]/n[k], t[k]/n[k] }' $S1/demux_qc/1A.read_start.tsv | sort -k1,1 -k2,2n
echo "##### cutadapt log head"; head -n 40 $S1/demux_qc/1A.cutadapt.log

echo "##### CRAMs (1A subsample): RG, duplicates, index"
for c in $S1/cram/*.cram $SI/cram_import/*.cram; do
    [ -f "$c" ] || continue
    tot=$($SAM view -@4 -c -T $REF "$c")
    rg=$($SAM view -@4 -c -T $REF -d RG "$c")
    dup=$($SAM view -@4 -c -T $REF -f 0x400 "$c")
    sec=$($SAM view -@4 -c -T $REF -f 0x900 "$c")
    q0=$($SAM view -@4 -c -T $REF -F 0x4 -q 1 "$c")
    unm=$($SAM view -@4 -c -T $REF -f 0x4 "$c")
    idx=no; [ -s "$c.crai" ] && idx=yes
    echo "$(basename $c) records=$tot with_RG=$rg dup_flagged=$dup sec_supp=$sec mapq_ge1=$q0 unmapped=$unm crai=$idx size=$(stat -c %s $c)"
    $SAM view -H "$c" | grep -E '^@RG|^@PG' | cut -c1-200 | head -n 8
done
echo "##### markdup stats (first sample of each store)"
for f in $(ls $S1/cram/*.markdup.stats | head -n 1) $SI/cram_import/*.markdup.stats; do echo "== $f"; cat "$f"; done
echo "##### QC files in stores"
ls -la $S1/cram | head -n 100
ls -la $SI/cram_import
ls -la $S1/registry $S1/demux_qc
echo "##### registry"; cat $S1/registry/*.tsv
echo "##### provenance (one BC1, one import)"
cat $(ls $S1/cram/*.provenance.json | head -n 1); echo
cat $(ls $SI/cram_import/*.provenance.json | head -n 1); echo
echo "##### published outputs"
find $O1 $OI -maxdepth 3 | sort | head -n 120
echo "##### trimmomatic trimlog sizes, summaries"
find $W/gate1_1A/work -name '*_trim.log' -printf '%s %p\n' | sort -n
for f in $(find $W/gate1_1A/work -name '*.summary' | head -n 3); do echo "== $f"; cat "$f"; done
echo "##### TRIMMOMATIC command line"
grep -h -m1 ILLUMINACLIP $(find $W/gate1_1A/work -name .command.sh | xargs grep -l trimmomatic | head -n 1)
echo "##### zg_resources lines"
for d in $W/gate1_1A/work $W/gate1_import/work; do grep -h "zg_resources" $(find $d -name .command.err) | sort | uniq -c | sort -rn | head -n 30; done
echo "##### Creating env"; grep -c "Creating env" $W/gate1_1A/launch/.nextflow.log $W/gate1_import/launch/.nextflow.log
echo "##### work size / files"
for d in $W/gate1_1A/work $W/gate1_import/work $W/gate1_1A/tmp $W/gate1_import/tmp; do du -sh $d; find $d -type f | wc -l; done
echo "##### trace"
for t in $O1/pipeline_info/execution_trace_*.txt $OI/pipeline_info/execution_trace_*.txt; do echo "== $t"; cut -f3,4,5,7,8,14,15,16,17,18,19 "$t" | column -t -s $'\t'; done
