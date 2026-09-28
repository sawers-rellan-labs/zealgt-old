# bin/export_slurm_resources.sh — sourced at the top of every local and patched module script:
#     source export_slurm_resources.sh
# by name, not by path: Nextflow puts the pipeline's bin/ on every task's PATH and bash `source` searches PATH (no exec bit
# needed, so core.fileMode=false on hazel does not matter). A path such as "${projectDir}/bin/..." would put the checkout
# location into every task hash (a second clone or a moved checkout would rerun everything).
#
# Why (PLAN §2 rule 4, hash hygiene): a task's hash covers its evaluated script text, so `${task.cpus}` / `${task.memory}`
# in a script turn every resource change (e.g. a retry at 48 GB) into a cache miss on the next -resume. Scripts therefore
# read threads and memory at run time from the Slurm allocation through this helper, never from task.*.
#
# Exports
#   ZG_CPUS         threads     <- SLURM_CPUS_PER_TASK (Nextflow's slurm executor submits -c <cpus>)
#   ZG_MEM_MB       memory, MB  <- SLURM_MEM_PER_NODE (the executor submits --mem; executor.perCpuMemAllocation off),
#                                  else SLURM_MEM_PER_CPU x ZG_CPUS
#   ZG_JAVA_MEM_MB  JVM heap for -Xmx (Picard, Trimmomatic, FastQC): ZG_MEM_MB minus a fixed ZG_JAVA_HEADROOM_MB (2048);
#                   left unset (with a warning) when that would be < 512 MB, so a JVM script using ${ZG_JAVA_MEM_MB}
#                   fails loudly under `set -u` instead of starting with a guessed heap.
# Explicit override (conf/local.config only, env scope): ZG_RESOURCES_OVERRIDE=local plus ZG_CPUS and ZG_MEM_MB. A ZG_CPUS
# or ZG_MEM_MB that leaks in from the submitting shell without ZG_RESOURCES_OVERRIDE=local is ignored in favour of Slurm.
# No silent default: with neither Slurm nor the override, the task stops here with a clear message.
# One line `zg_resources cpus=… mem_mb=… java_mem_mb=… source=… job=…` goes to stderr (.command.err / .command.log,
# not the script text, so it never enters the hash). If TMPDIR is set (conf/hazel.config env scope) it is created.
#
# Safe under the template's `bash -euo pipefail`. Run directly (`bash bin/export_slurm_resources.sh`) to print the values.

_zg_fail() {
    echo "zg_resources ERROR: $*" >&2
    return 1 2>/dev/null || exit 1
}

_zg_is_posint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

_zg_resources() {
    local src cpus mem mem_per_cpu headroom heap
    if [ "${ZG_RESOURCES_OVERRIDE:-}" = "local" ]; then
        src="override"
        cpus="${ZG_CPUS:-}"
        mem="${ZG_MEM_MB:-}"
        _zg_is_posint "$cpus" || { _zg_fail "ZG_RESOURCES_OVERRIDE=local but ZG_CPUS='${cpus}' is not a positive integer"; return 1; }
        _zg_is_posint "$mem"  || { _zg_fail "ZG_RESOURCES_OVERRIDE=local but ZG_MEM_MB='${mem}' is not a positive integer (MB)"; return 1; }
    elif [ -n "${SLURM_JOB_ID:-}" ]; then
        src="slurm"
        if [ -n "${ZG_CPUS:-}${ZG_MEM_MB:-}" ]; then
            echo "zg_resources: ignoring ZG_CPUS/ZG_MEM_MB from the environment (no ZG_RESOURCES_OVERRIDE=local); using Slurm" >&2
        fi
        cpus="${SLURM_CPUS_PER_TASK:-}"
        _zg_is_posint "$cpus" || { _zg_fail "SLURM_CPUS_PER_TASK='${cpus}' is not a positive integer (job ${SLURM_JOB_ID}; submitted without -c?)"; return 1; }
        mem="${SLURM_MEM_PER_NODE:-}"
        if ! _zg_is_posint "$mem"; then
            mem_per_cpu="${SLURM_MEM_PER_CPU:-}"
            _zg_is_posint "$mem_per_cpu" || { _zg_fail "neither SLURM_MEM_PER_NODE='${SLURM_MEM_PER_NODE:-}' nor SLURM_MEM_PER_CPU='${mem_per_cpu}' is a positive integer (job ${SLURM_JOB_ID})"; return 1; }
            mem=$(( mem_per_cpu * cpus ))
            src="slurm_per_cpu"
        fi
    else
        _zg_fail "no Slurm allocation (SLURM_JOB_ID unset) and no explicit override (ZG_RESOURCES_OVERRIDE=local + ZG_CPUS + ZG_MEM_MB, conf/local.config); refusing to guess resources"
        return 1
    fi

    export ZG_CPUS="$cpus" ZG_MEM_MB="$mem"
    headroom="${ZG_JAVA_HEADROOM_MB:-2048}"
    _zg_is_posint "$headroom" || { _zg_fail "ZG_JAVA_HEADROOM_MB='${headroom}' is not a positive integer"; return 1; }
    heap=$(( mem - headroom ))
    if [ "$heap" -ge 512 ]; then
        export ZG_JAVA_MEM_MB="$heap"
    else
        unset ZG_JAVA_MEM_MB
        echo "zg_resources: WARNING mem_mb=${mem} leaves < 512 MB heap after ${headroom} MB headroom; ZG_JAVA_MEM_MB unset (JVM tools will fail)" >&2
        heap="unset"
    fi

    if [ -n "${TMPDIR:-}" ]; then
        mkdir -p "$TMPDIR" || { _zg_fail "cannot create TMPDIR='${TMPDIR}'"; return 1; }
    fi

    echo "zg_resources cpus=${ZG_CPUS} mem_mb=${ZG_MEM_MB} java_mem_mb=${heap} source=${src} job=${SLURM_JOB_ID:-none} tmpdir=${TMPDIR:-unset} host=$(hostname)" >&2
}

_zg_resources || { return 1 2>/dev/null || exit 1; }
