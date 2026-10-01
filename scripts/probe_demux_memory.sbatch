#!/bin/bash
#SBATCH --job-name=zealgt_probe_demux
#SBATCH --account=maize_cpu
#SBATCH --partition=compute
#SBATCH --qos=normal
#SBATCH --time=03:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=3G
#SBATCH --output=/share/maize/frodrig4/nf_work/probe_demux_%j.log
#
# scripts/probe_demux_memory.sbatch — rerun one DEMUX task of a --subsample run on its FULL lane, in the task's own image and
# with its production request (batch-1: 4 cpu, 3 GB, conf/hazel.config), and sample the job's memory every 10 s, so memory
# growth with the data shows before a full-size run (CRAM Gate 2 w01: batch-1 DEMUX grew to the 2 GB and 4 GB limits).
#
#   sbatch scripts/probe_demux_memory.sbatch <DEMUX task dir of a --subsample run> <probe dir (new, on /share)>
#
# The task's .command.sh is copied with its --subsample branch switched off (`if [ "<lane_pairs>" -gt 0 ]` -> `if [ "0" ...`),
# so it takes the full-run path (tar members extracted to the probe dir, or the lane FASTQs read in place); the staged inputs
# are linked as in the task dir. Runs `bash -ue .command.sh` (Nextflow's shell) under `apptainer exec` with the binds of
# conf/hazel.config. Every 10 s one row to <probe dir>/memory.tsv: elapsed s, the job cgroup's memory.current and its
# anon / file split (memory.stat: anon = process memory, file = page cache, which hazel's sacct MaxRSS also counts), and the
# summed RSS of cutadapt, pigz and the rest of the job's processes. A summary line about once a minute in the log, with the
# demux output written so far. At the end: exit status, peak anon, outputs (.fastq.gz count, bytes), the cutadapt report.
# Writes only into <probe dir> (must not exist); removes nothing (the module's EXIT trap removes its own task-dir copies).
# No `set -u` (hazel-debug-loop skill).
set -eo pipefail
TASK="${1:?usage: sbatch scripts/probe_demux_memory.sbatch <DEMUX task dir> <probe dir>}"
OUT="${2:?usage: sbatch scripts/probe_demux_memory.sbatch <DEMUX task dir> <probe dir>}"
log() { echo "$(date '+%F %T') probe_demux: $*"; }
# absolute paths before any cd (the probe runs inside OUT; the task's binds are absolute): realpath -m does not need OUT to exist
TASK="$(realpath -m "$TASK")"; OUT="$(realpath -m "$OUT")"
[ -f "$TASK/.command.sh" ] && [ -f "$TASK/.command.run" ] || { log "ERROR: not a task dir: $TASK"; exit 1; }
grep -q 'cutadapt' "$TASK/.command.sh" && grep -q 'mkfifo' "$TASK/.command.sh" || { log "ERROR: not a DEMUX task (FIFO layout): $TASK"; exit 1; }
[ ! -e "$OUT" ] || { log "ERROR: probe dir exists (choose a new one): $OUT"; exit 1; }
SIF="$(grep -oE '/share/maize/frodrig4/apptainer/cache/[^ "]+\.img' "$TASK/.command.run" | head -1)"
[ -s "$SIF" ] || { log "ERROR: no image found in $TASK/.command.run (${SIF:-none})"; exit 1; }

mkdir -p "$OUT"
sed -E 's/^( *if \[ ")[0-9]+(" -gt 0 \]; then)$/\10\2/' "$TASK/.command.sh" > "$OUT/.command.sh"
n_sub="$(diff "$TASK/.command.sh" "$OUT/.command.sh" | grep -c '^>' || true)"
[ "$n_sub" = 1 ] || { log "ERROR: expected exactly one --subsample line to switch off, changed $n_sub"; exit 1; }
for d in raw_r1 raw_r2; do
    [ -d "$TASK/$d" ] || continue
    mkdir "$OUT/$d"
    for f in "$TASK/$d"/*; do ln -s "$(readlink -f "$f")" "$OUT/$d/$(basename "$f")"; done
done
log "job $SLURM_JOB_ID on $(hostname): task $TASK -> $OUT; image $SIF; $(nproc) cpus, request ${SLURM_MEM_PER_NODE:-?} MB"
log "inputs: $(ls -l "$OUT"/raw_r1/* "$OUT"/raw_r2/* 2>/dev/null | awk '{ print $NF }' | tr '\n' ' ')"

# The job's cgroup (cgroup v2; Slurm applies --mem there): the ancestor of this shell's cgroup named job_<id>
CG="/sys/fs/cgroup$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)"
while [ "$CG" != /sys/fs/cgroup ] && [ "$(basename "$CG")" != "job_$SLURM_JOB_ID" ]; do CG="$(dirname "$CG")"; done
[ -r "$CG/memory.current" ] || { log "ERROR: no job cgroup with memory.current found from $(cat /proc/self/cgroup)"; exit 1; }
log "job cgroup $CG (memory.max $(cat "$CG/memory.max"))"
job_pids() { find "$CG" -name cgroup.procs -exec cat {} + 2>/dev/null | paste -sd, -; }
export PATH=/usr/local/apps/apptainer/1.4.2-1/bin:$PATH
export TMPDIR="$OUT/tmp"; mkdir -p "$TMPDIR"
cd "$OUT"
start=$(date +%s)
# The task's own binds (Nextflow adds the inputs' directories, e.g. the raw data outside /rsstu/.../BZea, to the
# conf/hazel.config ones) and --pid, as its .command.run calls apptainer; the task dir itself is replaced by the probe dir
# (under /share/maize/frodrig4, bound).
BINDS="$(grep -m1 'apptainer exec' "$TASK/.command.run" | grep -oE -- '-B [^ "$]+' | awk '{ print $2 }' | grep -vxF "$TASK" | paste -sd, -)" || true
[ -n "$BINDS" ] || { log "ERROR: no -B binds found in $TASK/.command.run"; exit 1; }
log "binds: $BINDS"
apptainer exec --no-home --pid -B "$BINDS" "$SIF" bash -ue .command.sh > .command.out 2> .command.err &
app=$!

printf 'elapsed_s\tmem_current_mb\tanon_mb\tfile_mb\tcutadapt_rss_mb\tpigz_rss_mb\tother_rss_mb\tdemux_out_mb\n' > memory.tsv
peak_anon=0; last_log=0
while kill -0 "$app" 2>/dev/null; do
    now=$(( $(date +%s) - start ))
    cur=$(( $(cat "$CG/memory.current" 2>/dev/null || echo 0) / 1048576 ))
    read -r anon file < <(awk '$1 == "anon" { a = $2 } $1 == "file" { f = $2 } END { printf "%d %d\n", a / 1048576, f / 1048576 }' "$CG/memory.stat" 2>/dev/null || echo "0 0")
    read -r ca pz ot < <(ps -o rss=,comm= -p "$(job_pids)" 2>/dev/null | awk '{ if ($2 ~ /^cutadapt|^python/) c += $1; else if ($2 == "pigz") p += $1; else o += $1 }
                                                         END { printf "%d %d %d\n", c / 1024, p / 1024, o / 1024 }')
    dm=$(du -sm demux 2>/dev/null | cut -f1) || true; dm=${dm:-0}     # demux/ appears only once the script made it
    # cumulative CPU per process (ps `times` = user + sys seconds); the last value seen per pid is kept in cpu_by_pid.tsv
    ps -o pid=,ppid=,times=,comm=,args= -p "$(job_pids)" 2>/dev/null | awk -v t="$now" '{ a = ""; for (i = 5; i <= NF && i <= 9; i++) a = a " " $i
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", t, $1, $2, $3, $4, a }' >> cpu_samples.tsv || true
    printf '%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' "$now" "$cur" "$anon" "$file" "$ca" "$pz" "$ot" "$dm" >> memory.tsv
    [ "$anon" -le "$peak_anon" ] || peak_anon=$anon
    if [ $(( now - last_log )) -ge 60 ]; then
        log ">>> ${now} s | anon ${anon} MB (peak ${peak_anon}) | page cache ${file} MB | cutadapt ${ca} MB, pigz ${pz} MB | demux ${dm} MB written"
        last_log=$now
    fi
    sleep 10
done
rc=0; wait "$app" || rc=$?
log "DEMUX exit $rc after $(( $(date +%s) - start )) s; peak anon ${peak_anon} MB of the ${SLURM_MEM_PER_NODE:-?} MB request"
log "outputs: $(ls demux/*.fastq.gz 2>/dev/null | wc -l) .fastq.gz, $(du -sm demux 2>/dev/null | cut -f1) MB; other files in demux/: $(ls demux | grep -vc '\.fastq\.gz$' || true)"
tail -5 .command.err | sed 's/^/  stderr: /'
# CPU by role: the last sample of each pid (a process that lived < 10 s is missed). cutadapt's main process is the cutadapt
# whose parent is not a cutadapt; its children are the reader and the -j workers (the reader is the first child started).
awk -F'\t' '{ last[$2] = $0 } END { for (p in last) print last[p] }' cpu_samples.tsv | sort -t$'\t' -k2,2n > cpu_by_pid.tsv || true
awk -F'\t' '
    { pid[NR] = $2; ppid[NR] = $3; cpu[NR] = $4; comm[NR] = $5; args[NR] = $6; isc[$2] = ($5 == "cutadapt") }
    END {
        for (i = 1; i <= NR; i++) {
            if (comm[i] == "cutadapt") r = isc[ppid[i]] ? "cutadapt child (reader / worker)" : "cutadapt main"
            else if (comm[i] == "pigz" && args[i] ~ / -d/) r = "pigz -d (decompress)"
            else if (comm[i] == "pigz") r = "pigz -1 (compress outputs)"
            else if (comm[i] ~ /^igzip|^gzip/) r = comm[i] " (decompress)"
            else if (comm[i] == "tar") r = "tar (member extraction)"
            else r = "other (" comm[i] ")"
            s[r] += cpu[i]; n[r]++; tot += cpu[i]
            if (comm[i] == "cutadapt" && isc[ppid[i]]) printf "  cutadapt child pid %s: %.1f CPU-min\n", pid[i], cpu[i] / 60
        }
        for (r in s) printf "  %-34s %3d procs %7.1f CPU-min %5.1f %%\n", r, n[r], s[r] / 60, 100 * s[r] / tot
        printf "  %-34s %3s       %7.1f CPU-min (sampled; sacct TotalCPU is the reference)\n", "total", "", tot / 60
    }' cpu_by_pid.tsv | sed 's/^/  cpu: /' || true
grep -E 'Total read pairs processed|Pairs written|Read 1 with adapter' ./*.cutadapt.log 2>/dev/null | sed 's/^/  cutadapt: /' || true
exit "$rc"
