#!/usr/bin/env bash
# scripts/test_cache.sh — operator test of the CRAM workflow's cache behaviour (-resume) and of the stage split (PLAN §2/§3).
# nf-test cannot share a Nextflow session across runs, so this is a script (deliberate deviation, design brief Phase D).
#
#   bash scripts/test_cache.sh local                    laptop: -profile test (fixture LIBX), real tools on PATH
#   sbatch scripts/test_cache.sbatch                    hazel: runs `test_cache.sh hazel` inside a head job (never login)
#   bash scripts/test_cache.sh report <scratch dir>     re-run only the assertions / hash tables on a finished scratch dir
#
# What it does (all in a scratch dir; nothing tracked is touched, nothing is ever removed):
#   0. git clone of this checkout's HEAD into <scratch>/repo (core.fileMode false, as on hazel): R3 edits a module there.
#      Uncommitted changes of the checkout are NOT tested (warned).
#   R1  read_demultiplexing chained into stage 2, -dump-hashes json                        -> every task runs
#   PF  preflight: -stub run with R2's profiles + configs (local executor, big pool)          -> its trace shows the raised
#       resources; asserts cpus, memory and time are higher than R1's for every process (else R2 would prove nothing)
#   R2  -resume <R1 session> + tests/cache/raise_<mode>.config (every process more cpus/memory/time), fresh store
#                                                                                           -> every task CACHED
#   R3  -resume <R1 session> after a committed edit of ALIGN_MARKDUP's script: block in the clone (harmless: `|| true`
#       -> `|| :`), fresh store                          -> every stage-1 task CACHED, every ALIGN_MARKDUP task re-executed
#   R4  --entry read_alignment on R1's FASTQ checkpoint, fresh store (new session)     -> only stage-2 tasks, no stage 1
#   Report: status per process per run (from the traces), the per-task hash dumps of R1/R2/R3 side by side, the hash
#   component(s) that changed for ALIGN_MARKDUP in R3 -> <scratch>/summary.txt. Exit 1 on any failed assertion.
#
# ONE launch dir for R1-R4 (<scratch>/launch: .nextflow/ history + cache db of the session). The store path given to
# Nextflow is always <scratch>/store_live/<leaf>, a symlink re-pointed to an empty <scratch>/stores/rN/<leaf> before each
# run: the store path is part of the provenance record (a PROVENANCE input), so R2 differs from R1 only in resources, yet
# every run starts from an empty store (a stored CRAM would be skipped, not cached). The FASTQ checkpoint
# (<scratch>/checkpoint/<leaf>) is shared by all runs (R1 writes it, R2/R3 re-link the same files, R4 reads it).
#
# Mode local: scratch $ZG_CACHETEST_ROOT (default <checkout>/agent/cachetest)/<time>; tools from $ZG_CACHETEST_PATH
#   (default the main checkout's agent/bin + agent/localbin + /opt/homebrew/bin); NXF_VER 26.04.6 unless set.
# Mode hazel (Gate 1 scale): library 1A, --subsample 1000000 --force_demux 1A, -profile hazel,short, Slurm tasks;
#   scratch $ZG_CACHETEST_ROOT (default /share/maize/frodrig4/nf_work/simplify_cachetest)/<time>; work/, TMPDIR, stores,
#   checkpoint all under it, store and checkpoint named subsample_1000000 (run guards), never the production ZEAL/store.
#   Needs SLURM_JOB_ID (a head job: scripts/test_cache.sbatch) and nextflow on PATH.
# Clean-up is the user's: the scratch dir is printed at the end (work/ of 5 runs, stores, checkpoint).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
export NXF_ANSI_LOG=false

if [ "$MODE" = "report" ]; then
    S="$(cd "${2:?usage: test_cache.sh report <scratch dir>}" && pwd)"
    python3 "$REPO/tests/cache/cache_report.py" "$S"
    exit $?
fi

TS="$(date +%Y%m%d_%H%M%S)"
case "$MODE" in
    local)
        BASE="${ZG_CACHETEST_ROOT:-$REPO/agent/cachetest}"
        A=/Users/fvrodriguez/repos/zealgt/agent
        export PATH="${ZG_CACHETEST_PATH:-$A/bin:$A/localbin:/opt/homebrew/bin}:$PATH"
        export NXF_VER="${NXF_VER:-26.04.6}"
        PROFILE=test
        LEAF=store
        CKPT_LEAF=checkpoint
        RUN_ARGS=(--run_id cachetest)
        DEMUX_ARGS=(--entry read_demultiplexing)
        MODE_CONFIG=tests/cache/local.config
        ;;
    hazel)
        [ -n "${SLURM_JOB_ID:-}" ] || { echo "test_cache.sh hazel runs inside a Slurm head job: sbatch scripts/test_cache.sbatch" >&2; exit 2; }
        BASE="${ZG_CACHETEST_ROOT:-/share/maize/frodrig4/nf_work/simplify_cachetest}"
        PROFILE=hazel,short
        LEAF=subsample_1000000
        CKPT_LEAF=subsample_1000000
        RUN_ARGS=(--run_id simplify_cachetest --workflow cram --libraries 1A --subsample 1000000)
        DEMUX_ARGS=(--entry read_demultiplexing --force_demux 1A)
        MODE_CONFIG=''
        ;;
    *)
        echo "usage: test_cache.sh local | hazel | report <scratch dir>" >&2
        exit 2
        ;;
esac
command -v nextflow >/dev/null || { echo "test_cache.sh: nextflow not on PATH" >&2; exit 2; }

S="$BASE/$TS"
[ ! -e "$S" ] || { echo "test_cache.sh: $S exists" >&2; exit 2; }
mkdir -p "$S"/{launch,logs,traces,stores,store_live,preflight/launch}
C="$S/repo"
echo "test_cache: mode=$MODE scratch=$S"
echo "test_cache: checkout $REPO commit $(git -C "$REPO" rev-parse HEAD)"
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
    echo "test_cache: WARNING the checkout has uncommitted changes to tracked files; the clone tests HEAD only"
fi
git clone -q "$REPO" "$C"
git -C "$C" config core.fileMode false
echo "test_cache: clone $C commit $(git -C "$C" rev-parse HEAD)"

# per-run config (paths of this scratch dir): trace fields, and on hazel TMPDIR under the scratch dir (conf/hazel.config
# would put it under nf_work/<run_id>/tmp). Directives and env only: nothing here is in a task hash.
RUN_CONFIG="$S/run.config"
{
    echo "trace.fields    = 'task_id,hash,process,tag,name,status,exit,attempt,cpus,memory,time,queue'"
    echo "trace.overwrite = true"
    if [ "$MODE" = hazel ]; then
        echo "env.TMPDIR = '$S/tmp'"
        echo "process.beforeScript = \"mkdir -p '$S/tmp'\""
    fi
} > "$RUN_CONFIG"
CONFIGS=()
[ -z "$MODE_CONFIG" ] || CONFIGS+=(-c "$C/$MODE_CONFIG")
CONFIGS+=(-c "$RUN_CONFIG")
RAISE=(-c "$C/tests/cache/raise_$MODE.config")
CKPT="$S/checkpoint/$CKPT_LEAF"
STORE="$S/store_live/$LEAF"

# fresh empty store for run $1 behind the fixed store path (ln -sfn replaces only the symlink)
use_store() {
    mkdir -p "$S/stores/$1/$LEAF"
    ln -sfn "$S/stores/$1/$LEAF" "$STORE"
    echo "test_cache: $1 store $STORE -> $(readlink "$STORE")"
}

# nextflow run from the launch dir; console to logs/<run>.console.txt (and to stdout), log to logs/<run>.nextflow.log
run_nf() {
    local tag="$1" dir="$2"; shift 2
    echo "test_cache: == $tag: nextflow run $*"
    set +e
    ( cd "$dir" && nextflow -log "$S/logs/$tag.nextflow.log" run "$C" "$@" ) 2>&1 | tee "$S/logs/$tag.console.txt"
    local rc=${PIPESTATUS[0]}
    set -e
    echo "test_cache: == $tag: nextflow exit $rc"
    echo "$rc" > "$S/logs/$tag.exit"
    return 0
}

session_of() {
    grep -oE "Session UUID: [0-9a-f-]{36}" "$S/logs/$1.nextflow.log" | head -n 1 | awk '{ print $3 }'
}

COMMON=(-profile "$PROFILE" "${CONFIGS[@]}" "${RUN_ARGS[@]}" -w "$S/work" --fastq_checkpoint "$CKPT" --outdir "$STORE")

# R1: chained read_demultiplexing, every task runs
use_store r1
run_nf r1 "$S/launch" "${COMMON[@]}" "${DEMUX_ARGS[@]}" \
    -with-trace "$S/traces/r1.txt" -dump-hashes json
SID="$(session_of r1)"
[ -n "$SID" ] || { echo "test_cache: no session id in $S/logs/r1.nextflow.log" >&2; exit 1; }
echo "$SID" > "$S/logs/r1.session"
echo "test_cache: R1 session $SID"
if [ "$(cat "$S/logs/r1.exit")" != 0 ]; then
    echo "test_cache: R1 failed; nothing to compare (see $S/logs/r1.console.txt)" >&2
    python3 "$C/tests/cache/cache_report.py" "$S" || true
    exit 1
fi

# PF: the resources R2 would request (stub run, own launch dir/work/store_stub/checkpoint_stub; not part of the session)
mkdir -p "$S/preflight/store_stub/$LEAF" "$S/preflight/checkpoint_stub"
run_nf preflight "$S/preflight/launch" -profile "$PROFILE" "${CONFIGS[@]}" "${RAISE[@]}" -c "$C/tests/cache/preflight.config" \
    "${RUN_ARGS[@]}" -stub -w "$S/preflight/work" "${DEMUX_ARGS[@]}" \
    --outdir "$S/preflight/store_stub/$LEAF" --fastq_checkpoint "$S/preflight/checkpoint_stub/$CKPT_LEAF" \
    -with-trace "$S/traces/preflight.txt"

# R2: resources raised for every process -> every task cached
use_store r2
run_nf r2 "$S/launch" "${COMMON[@]}" "${RAISE[@]}" "${DEMUX_ARGS[@]}" \
    -with-trace "$S/traces/r2.txt" -dump-hashes json -resume "$SID"

# R3: ALIGN_MARKDUP's script edited (committed in the clone, as a fix would be) -> stage 1 cached, ALIGN_MARKDUP re-executed
python3 "$C/tests/cache/edit_align_markdup.py" "$C/modules/local/align_markdup/main.nf"
git -C "$C" -c user.name=test_cache -c user.email=test_cache@localhost commit -q -m "test_cache: harmless edit of ALIGN_MARKDUP's script" modules/local/align_markdup/main.nf
echo "test_cache: clone now at $(git -C "$C" rev-parse HEAD) ($(git -C "$C" diff --stat HEAD~1 HEAD | tail -n 1))"
use_store r3
run_nf r3 "$S/launch" "${COMMON[@]}" "${DEMUX_ARGS[@]}" \
    -with-trace "$S/traces/r3.txt" -dump-hashes json -resume "$SID"

# R4: stage 2 alone from R1's checkpoint, new session -> only stage-2 tasks
use_store r4
run_nf r4 "$S/launch" "${COMMON[@]}" --entry read_alignment \
    -with-trace "$S/traces/r4.txt" -dump-hashes json

rc=0
python3 "$C/tests/cache/cache_report.py" "$S" || rc=$?
echo "test_cache: summary $S/summary.txt"
echo "test_cache: scratch $S (work/, stores/, checkpoint/, preflight/) is left in place; removing it is the user's call"
exit "$rc"
