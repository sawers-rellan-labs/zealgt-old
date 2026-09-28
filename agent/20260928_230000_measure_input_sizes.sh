#!/usr/bin/env bash
# Read-only: for every COMPLETED TRIMMOMATIC / FASTQC / ALIGN_MARKDUP / PICARD_COLLECTWGSMETRICS task in the Gate 2 traces,
# print process, tag, attempt, memory, realtime, rchar, and the dereferenced sizes of the staged *.fastq.gz / *.cram inputs.
# Nothing is written on hazel.
set -u
D=/rsstu/users/r/rrellan/BZea/ZEAL/results/zealgt/gate2_3A/pipeline_info
printf 'process\ttag\tattempt\tmemory\trealtime\trchar\tread_bytes\tinputs(name=bytes)\n'
for t in "$D"/execution_trace_*.txt; do
  awk -F'\t' 'NR>1 && $7=="COMPLETED" {print $4"\t"$5"\t"$9"\t"$17"\t"$14"\t"$20"\t"$22"\t"$24}' "$t"
done | while IFS=$'\t' read -r proc tag att mem rt rchar rb wd; do
  p=${proc##*:}
  case "$p" in TRIMMOMATIC|FASTQC|ALIGN_MARKDUP|PICARD_COLLECTWGSMETRICS) ;; *) continue ;; esac
  ins=""
  if [ -d "$wd" ]; then
    for f in "$wd"/*; do
      [ -L "$f" ] || continue
      case "$f" in *.fastq.gz|*.fq.gz|*.cram) ;; *) continue ;; esac
      s=$(stat -L -c %s "$f" 2>/dev/null || echo NA)
      ins="$ins $(basename "$f")=$s"
    done
  else
    ins=" workdir_missing"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$tag" "$att" "$mem" "$rt" "$rchar" "$rb" "$ins"
done
