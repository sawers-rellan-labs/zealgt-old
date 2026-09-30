#!/usr/bin/env bash
# scripts/build_envs.sh — build every zealgt environment once, from the repo, into /share (never at task time, never on /rsstu).
#
# Since the container switch (2026-09-30, docs/PLAN_containers.md step 5) the pipeline's processes run in container images
# and have no conda env on hazel. What is left for this script is the non-module envs under envs/: today only the Nextflow
# launcher (envs/nextflow, used by scripts/submit_head_job.sbatch via --list), until it is replaced by the single-file
# launcher + a pinned Java (docs/PLAN_containers.md §6, option B). The modules' environment.yml files stay (nf-core rule:
# the Seqera images are built from them) but are not built here any more, and conf/env_prefixes.config is gone.
#   envs/<name>/environment.yml                      the non-module envs (the launcher), built first
#   + an optional build.sh next to the environment.yml (envs/nextflow/build.sh fetches the nf-schema plugin into the
#     prefix). build.sh runs inside the new env (`conda run -p <prefix>`) with ZG_ENV_DIR (its own directory) and
#     ZG_BUILD_DIR (a scratch dir inside the prefix, kept as the source record) exported. Declare the pinned source(s) in
#     build.sh with lines `# zg-source: <url>@<commit>`.
#
# Env id: the path under envs/ (nextflow); process name = upper-case id (NEXTFLOW).
#
# Prefix = CONTENT only: ${ZG_ENV_ROOT}/<first dependency>-<sha8>, sha8 = first 8 hex of sha256( the environment.yml without
# comment lines, blank lines, trailing comments and the `name:` line ++ build.sh bytes if present ), <first dependency> =
# the package name of the yml's first dependency (e.g. python, cutadapt, minibwa, nextflow), so the name is a function of the
# content alone. Every process whose env has the same content points at the same prefix (DEMUX_QC, PROVENANCE and REGISTRY
# are python-only: one prefix), in this checkout and in any other branch built into the same root. A comment edit in an
# environment.yml changes nothing; a dependency, channel or build.sh change gives a new prefix (a build, and new task hashes:
# Nextflow hashes the conda prefix path).
# A prefix that already exists with its success record (.zg_env_info.tsv) is skipped; a prefix that exists WITHOUT it (a
# failed earlier build) is reported and left alone. This script NEVER deletes anything: prefixes no longer referenced are only
# listed (--list-stale), for removal by hand with the user's consent.
#
# Smoke test: the command(s) in envs/smoke_tests.tsv (env_id<TAB>command, run inside the env) of every env id sharing the
# prefix; always also a check that every pinned dependency of environment.yml is installed at the pinned version/build
# (`conda list --export`).
#
# Usage
#   scripts/build_envs.sh --list            one row per process: env id, process, env dir, sha8, prefix (launcher row
#                                           "nextflow" first; read by submit_head_job.sbatch / test_cache.sbatch). No conda
#                                           needed; works on the laptop.
#   scripts/build_envs.sh --prefixes        one row per prefix: prefix, sha8, env ids, processes, on-disk state
#   scripts/build_envs.sh [--only <id>]...  build (hazel, as the xfer job scripts/build_envs.sbatch; compute nodes are offline)
#   scripts/build_envs.sh --list-stale [--all-refs | <git ref>...]
#                                           dirs under ZG_ENV_ROOT that neither this checkout nor the named git refs (their
#                                           committed conf/env_prefixes.config + launcher env) reference; --all-refs = every
#                                           local and remote branch of this clone. Lists only, never removes.
#   scripts/build_envs.sh --inodes [<prefix>...]
#                                           own inodes per prefix (`find <prefix> ! -type f -o -type f -links 1 | wc -l`:
#                                           dirs, links and files not hardlinked from the pkgs cache) and all entries;
#                                           default: every dir under ZG_ENV_ROOT
#
# Output of a build: ${ZG_ENV_ROOT}/manifest.tsv and envs/manifest.tsv, one row per prefix of this checkout (modules,
# processes, prefix, sha8, status, sources, tool versions, file count, build time, conda version, own inodes). envs/manifest.tsv
# is a build record of the hazel checkout (gitignored); the durable per-prefix record is <prefix>/.zg_env_info.tsv.

set -eo pipefail

ZG_ENV_ROOT="${ZG_ENV_ROOT:-/share/maize/frodrig4/conda/zealgt}"
ZG_CONDA="${ZG_CONDA:-/usr/local/apps/conda/miniconda3/26.3.2/bin/conda}"
export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-/share/maize/frodrig4/conda/pkgs}"
export CONDA_CHANNEL_PRIORITY=strict

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "build_envs: ERROR: $*" >&2; exit 1; }
log() { echo "build_envs: $(date '+%F %T') $*" >&2; }

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
    else shasum -a 256 | cut -c1-64; fi
}

# norm_yml [file]: the environment.yml as conda reads it, without comments, blank lines, trailing blanks and `name:`
# (ignored by `conda env create -p`). Reads stdin without an argument.
norm_yml() {
    awk '
        /^[ \t]*#/ || /^[ \t]*$/ || /^name:/ { next }
        { sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, ""); print }' "${1:--}"
}

# deps of an environment.yml as name<TAB>version<TAB>build (version/build empty when not pinned); pip sections skipped.
# Reads stdin without an argument.
yml_deps() {
    awk '
        /^dependencies:/ { in_deps = 1; ind = -1; next }
        in_deps && /^[^ \t-]/ { in_deps = 0 }
        in_deps && /^[ ]*- / {
            match($0, /^[ ]*/); i = RLENGTH
            if (ind < 0) ind = i
            if (i != ind) next                       # nested list (pip:) items
            s = $0; sub(/^[ ]*- /, "", s); sub(/[ \t]*#.*$/, "", s); gsub(/[ \t"\047]/, "", s)
            if (s ~ /^pip:?$/ || s == "") next
            sub(/^.*::/, "", s)
            if (s ~ /[<>!~*]/) { split(s, b, /[<>!~=*]/); print b[1] "\t\t"; next }
            n = split(s, a, "=")
            if (n >= 3) print a[1] "\t" a[2] "\t" a[3]; else if (n == 2) print a[1] "\t" a[2] "\t"; else print a[1] "\t\t"
        }' "${1:--}"
}

# env_sha8 <env dir>
env_sha8() {
    local d="$1"
    {
        norm_yml "$d/environment.yml"
        if [ -f "$d/build.sh" ]; then cat "$d/build.sh"; fi
    } | sha256_stdin | cut -c1-8
}

# env_label [yml]: lower-case package name of the first dependency (stdin without an argument); "env" if there is none
env_label() {
    yml_deps "${1:--}" | awk -F'\t' 'NR == 1 { n = tolower($1); gsub(/[^a-z0-9._-]/, "_", n); print n } END { if (NR == 0) print "env" }'
}

# Env dirs as id<TAB>dir (relative to the repo), launcher (envs/nextflow) first, then by id.
list_env_dirs() {
    local f d rel id base
    {
        for f in "$REPO"/envs/*/environment.yml; do
            [ -f "$f" ] || continue
            d="$(dirname "$f")"; rel="${d#"$REPO"/}"; id="${rel#envs/}"
            if [ "$id" = "nextflow" ]; then printf '0\t%s\t%s\n' "$id" "$rel"; else printf '1\t%s\t%s\n' "$id" "$rel"; fi
        done
    } | sort -t$'\t' -k1,1 -k2,2 | cut -f2,3
}

# One row per env: id<TAB>process<TAB>env dir<TAB>sha8<TAB>prefix; the launcher (id nextflow, process NEXTFLOW) first.
list_envs() {
    local id rel sha label rows="" alias target hit
    while IFS=$'\t' read -r id rel; do
        sha="$(env_sha8 "$REPO/$rel")"
        label="$(env_label "$REPO/$rel/environment.yml")"
        rows="$rows$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$(echo "$id" | tr '[:lower:]-' '[:upper:]_')" "$rel" "$sha" "$ZG_ENV_ROOT/$label-$sha")"$'\n'
    done < <(list_env_dirs)
    printf '%s' "$rows"
}

# One row per prefix (first appearance order, so the launcher first): prefix<TAB>sha8<TAB>env dir of its first env id<TAB>
# env ids (comma)<TAB>processes (comma)
list_prefixes() {
    list_envs | awk -F'\t' 'BEGIN{OFS="\t"}
        !($5 in seen) { seen[$5] = ++n; pfx[n] = $5; sha[n] = $4; dir[n] = $3 }
        { k = seen[$5]
          if (index("," ids[k] ",", "," $1 ",") == 0) ids[k] = (ids[k] == "" ? $1 : ids[k] "," $1)
          procs[k] = (procs[k] == "" ? $2 : procs[k] "," $2) }
        END { for (i = 1; i <= n; i++) print pfx[i], sha[i], dir[i], ids[i], procs[i] }'
}

check_unique() {
    local dup
    dup="$(list_env_dirs | cut -f1 | sort | uniq -d)"
    [ -z "$dup" ] || die "env ids not unique (same module name under nf-core and local?): $dup"
}

# in_lines <word> <newline-separated list>: exact line match, no pipe (grep -q in a pipe can turn a match into SIGPIPE)
in_lines() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0;; *) return 1;; esac; }

# own_inodes <prefix>: entries of the prefix that are not hardlinks of a file elsewhere (the conda pkgs cache)
own_inodes() { find "$1" ! -type f -o -type f -links 1 | wc -l | tr -d ' '; }

# prefix_state <prefix>: built (success record), failed (dir without it), absent
prefix_state() {
    if [ -f "$1/.zg_env_info.tsv" ]; then echo built; elif [ -e "$1" ]; then echo failed_or_partial; else echo absent; fi
}

# Prefixes referenced by the committed tree of a git ref: its conf/env_prefixes.config, plus its launcher prefix under both
# naming schemes (raw-bytes <id>-<sha8> before 2026-09-29 and content <first dependency>-<sha8> now), so a stale listing
# never names a prefix another branch still uses.
ref_prefixes() {
    local ref="$1" sha
    git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || die "not a git ref in $REPO: $ref"
    # the committed config names /share paths; compared by name under ZG_ENV_ROOT
    git -C "$REPO" show "$ref:conf/env_prefixes.config" 2>/dev/null | grep -oE "conda = '[^']+'" | sed "s/'\$//; s|^.*/||; s|^|$ZG_ENV_ROOT/|" || true
    git -C "$REPO" cat-file -e "$ref:envs/nextflow/environment.yml" 2>/dev/null || return 0
    sha="$({ git -C "$REPO" show "$ref:envs/nextflow/environment.yml"; git -C "$REPO" show "$ref:envs/nextflow/build.sh" 2>/dev/null || true; } | sha256_stdin | cut -c1-8)"
    echo "$ZG_ENV_ROOT/nextflow-$sha"
    sha="$({ git -C "$REPO" show "$ref:envs/nextflow/environment.yml" | norm_yml; git -C "$REPO" show "$ref:envs/nextflow/build.sh" 2>/dev/null || true; } | sha256_stdin | cut -c1-8)"
    echo "$ZG_ENV_ROOT/$(git -C "$REPO" show "$ref:envs/nextflow/environment.yml" | env_label)-$sha"
}

list_stale() {
    local refs=() ref referenced d info
    [ -d "$ZG_ENV_ROOT" ] || die "ZG_ENV_ROOT $ZG_ENV_ROOT does not exist here (run on hazel)"
    if [ "${1:-}" = "--all-refs" ]; then
        while IFS= read -r ref; do refs+=("$ref"); done < <(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads refs/remotes | grep -v '/HEAD$')
    else
        refs=("$@")
    fi
    referenced="$( { list_envs | cut -f5; for ref in "${refs[@]}"; do ref_prefixes "$ref"; done; } | sort -u)"
    echo "build_envs: prefixes under $ZG_ENV_ROOT referenced by neither this checkout ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')) nor ${#refs[@]} git ref(s)${refs[*]:+: ${refs[*]}}" >&2
    echo "build_envs: listing only. A running or queued job of another checkout may still use one; remove a prefix only with the user's consent." >&2
    printf 'prefix\tstate\tbuilt_at\tmodules\n'
    while IFS= read -r d; do
        if in_lines "$d" "$referenced"; then continue; fi
        info="$d/.zg_env_info.tsv"
        if [ -f "$info" ]; then
            tail -1 "$info" | awk -F'\t' -v d="$d" 'BEGIN{OFS="\t"} { print d, "built", $9, $1 }'
        else
            printf '%s\t%s\t\t\n' "$d" "$(prefix_state "$d")"
        fi
    done < <(find "$ZG_ENV_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
}

list_inodes() {
    local d referenced
    [ -d "$ZG_ENV_ROOT" ] || die "ZG_ENV_ROOT $ZG_ENV_ROOT does not exist here (run on hazel)"
    referenced="$(list_envs | cut -f5 | sort -u)"
    printf 'prefix\treferenced_here\town_inodes\tall_entries\n'
    {
        if [ $# -gt 0 ]; then printf '%s\n' "$@"; else find "$ZG_ENV_ROOT" -mindepth 1 -maxdepth 1 -type d | sort; fi
    } | while IFS= read -r d; do
        [ -d "$d" ] || { echo "build_envs: not a directory: $d" >&2; continue; }
        printf '%s\t%s\t%s\t%s\n' "$d" "$(if in_lines "$d" "$referenced"; then echo yes; else echo no; fi)" \
            "$(own_inodes "$d")" "$(find "$d" | wc -l | tr -d ' ')"
    done
}

show_prefixes() {
    local prefix sha dir ids procs
    printf 'prefix\tsha8\tenv_ids\tprocesses\tstate_here\n'
    while IFS=$'\t' read -r prefix sha dir ids procs; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$prefix" "$sha" "$ids" "$procs" "$(prefix_state "$prefix")"
    done < <(list_prefixes)
}

# verify_pins <prefix> <yml> ; prints the checked pins as name=version=build;... and fails on a mismatch
verify_pins() {
    local prefix="$1" yml="$2" exported name ver build hit out=""
    exported="$("$ZG_CONDA" list -p "$prefix" --export)"
    while IFS=$'\t' read -r name ver build; do
        # conda normalises names to lower case; the nf-core yml may pin e.g. "bioconda::multiqc=1.25.1"
        name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
        hit="$(echo "$exported" | awk -F= -v n="$name" '$1==n {print; exit}')"
        [ -n "$hit" ] || { echo "missing package $name in $prefix" >&2; return 1; }
        if [ -n "$ver" ] && [ "$(echo "$hit" | cut -d= -f2)" != "$ver" ]; then
            echo "version mismatch for $name: pinned $ver, installed $hit" >&2; return 1
        fi
        if [ -n "$build" ] && [ "$(echo "$hit" | cut -d= -f3)" != "$build" ]; then
            echo "build mismatch for $name: pinned $build, installed $hit" >&2; return 1
        fi
        out="${out:+$out;}$hit"
    done < <(yml_deps "$yml")
    echo "$out"
}

# smoke commands of the env ids (comma list), duplicates dropped, one per line
smoke_cmds() {
    [ -f "$REPO/envs/smoke_tests.tsv" ] || return 0
    awk -F'\t' -v ids="$1" 'BEGIN { n = split(ids, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        ($1 in want) { c = substr($0, index($0, "\t") + 1); if (!(c in seen)) { seen[c] = 1; print c } }' "$REPO/envs/smoke_tests.tsv"
}

# manifest row: modules processes prefix sha8 status sources tool_versions n_files built_at conda own_inodes
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

build_one() {
    local prefix="$1" sha="$2" rel="$3" ids="$4" procs="$5"
    local dir="$REPO/$rel" info="$prefix/.zg_env_info.tsv" sources pins smoke smoke_out out nfiles owni cv
    cv="$("$ZG_CONDA" --version 2>&1)"
    sources="$(grep -hoE '^# zg-source: .*' "$dir/build.sh" 2>/dev/null | sed 's/^# zg-source: //' | paste -sd, - || true)"
    fail() { log "FAILED $prefix ($ids): $1"; row "$ids" "$procs" "$prefix" "$sha" "failed_$2" "$sources" "" "" "$(date '+%F %T')" "$cv" ""; return 1; }
    if [ -f "$info" ]; then
        log "skip $prefix ($ids): exists (built $(tail -1 "$info" | cut -f9))"
        tail -1 "$info" | awk -F'\t' -v ids="$ids" -v procs="$procs" 'BEGIN{OFS="\t"} {$1 = ids; $2 = procs; $5 = "skipped_exists"; print}'
        return 0
    fi
    if [ -e "$prefix" ]; then
        fail "$prefix exists without .zg_env_info.tsv (an earlier build failed); left untouched, remove it by hand with consent" stale_prefix
        return 1
    fi
    log "build $prefix for $ids (from $rel/environment.yml)"
    "$ZG_CONDA" env create -p "$prefix" -f "$dir/environment.yml" >&2 || { fail "conda env create" create; return 1; }
    if [ -f "$dir/build.sh" ]; then
        local bdir="$prefix/share/zg_build"
        mkdir -p "$bdir"
        log "build.sh for $prefix (sources: ${sources:-none declared})"
        ZG_ENV_DIR="$dir" ZG_BUILD_DIR="$bdir" "$ZG_CONDA" run -p "$prefix" --no-capture-output bash "$dir/build.sh" >&2 \
            || { fail "build.sh" build_sh; return 1; }
    fi
    pins="$(verify_pins "$prefix" "$dir/environment.yml")" || { fail "pinned packages not as specified" pins; return 1; }
    smoke_out="pins_ok"
    while IFS= read -r smoke; do
        [ -n "$smoke" ] || continue
        out="$("$ZG_CONDA" run -p "$prefix" bash -c "$smoke" 2>&1)" || { fail "smoke test '$smoke': $out" smoke; return 1; }
        out="$(echo "$out" | grep -v '^[[:space:]]*$' | awk 'NR == 1' | tr '\t' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ "$smoke_out" = pins_ok ]; then smoke_out="$out"; else smoke_out="$smoke_out / $out"; fi
    done < <(smoke_cmds "$ids")
    nfiles="$(find "$prefix" | wc -l | tr -d ' ')"
    owni="$(own_inodes "$prefix")"
    row "$ids" "$procs" "$prefix" "$sha" "built" "$sources" "$smoke_out | $pins" "$nfiles" "$(date '+%F %T')" "$cv" "$owni" | tee "$info"
    log "ok $prefix ($nfiles entries, $owni own inodes): $smoke_out"
}

MANIFEST_HEADER=$'modules\tprocesses\tprefix\tsha8\tstatus\tsources\ttool_versions\tn_files\tbuilt_at\tconda\town_inodes'

main_build() {
    local only=("$@") rows rc=0 prefix sha rel ids procs row sel id
    [ -x "$ZG_CONDA" ] || die "conda binary not found at $ZG_CONDA"
    case "$ZG_ENV_ROOT" in /rsstu/*) die "ZG_ENV_ROOT on /rsstu is not allowed (too slow; user 2026-09-28)";; esac
    check_unique
    for id in "${only[@]}"; do
        in_lines "$id" "$(list_env_dirs | cut -f1)" || die "--only: unknown env id '$id' (see --list)"
    done
    mkdir -p "$ZG_ENV_ROOT" "$CONDA_PKGS_DIRS"
    log "root $ZG_ENV_ROOT, pkgs $CONDA_PKGS_DIRS, $("$ZG_CONDA" --version 2>&1), channel priority $CONDA_CHANNEL_PRIORITY, host $(hostname)"
    rows="$MANIFEST_HEADER"
    while IFS=$'\t' read -r prefix sha rel ids procs; do
        sel=1
        if [ "${#only[@]}" -gt 0 ]; then
            sel=0
            for id in "${only[@]}"; do case ",$ids," in *",$id,"*) sel=1;; esac; done
        fi
        if [ "$sel" = 0 ]; then
            # not selected: keep it in the manifest as it stands on disk
            if [ -f "$prefix/.zg_env_info.tsv" ]; then
                row="$(tail -1 "$prefix/.zg_env_info.tsv" | awk -F'\t' -v ids="$ids" -v procs="$procs" 'BEGIN{OFS="\t"} {$1 = ids; $2 = procs; $5 = "present"; print}')"
            else
                row="$(row "$ids" "$procs" "$prefix" "$sha" "not_built" "" "" "" "" "" "")"
            fi
            rows="$rows"$'\n'"$row"
            continue
        fi
        if row="$(build_one "$prefix" "$sha" "$rel" "$ids" "$procs")"; then :; else rc=1; fi
        [ -n "$row" ] && rows="$rows"$'\n'"$row"
        # the launcher env comes first; stop if it failed (nothing downstream can run without it)
        case ",$ids," in *",nextflow,"*) if [ "$rc" -ne 0 ]; then log "launcher env failed; stopping"; break; fi;; esac
    done < <(list_prefixes)
    printf '%s\n' "$rows" > "$ZG_ENV_ROOT/manifest.tsv"
    cp "$ZG_ENV_ROOT/manifest.tsv" "$REPO/envs/manifest.tsv"
    log "manifest: $ZG_ENV_ROOT/manifest.tsv (this checkout's prefixes; copied to envs/manifest.tsv); exit $rc"
    return "$rc"
}

case "${1:-}" in
    --list)         check_unique; list_envs ;;
    --prefixes)     check_unique; show_prefixes ;;
    --write-config|--check-config) die "$1 was removed with the container switch (no module envs, no conf/env_prefixes.config)" ;;
    --list-stale)   shift; check_unique; list_stale "$@" ;;
    --inodes)       shift; check_unique; list_inodes "$@" ;;
    --deps)         yml_deps "$2" ;;
    --only)         shift; ids=(); while [ $# -gt 0 ]; do [ "$1" = "--only" ] || ids+=("$1"); shift; done; main_build "${ids[@]}" ;;
    "")             main_build ;;
    -h|--help)      awk 'NR > 1 && /^set -eo/ {exit} NR > 1 {print}' "${BASH_SOURCE[0]}" ;;
    *)              die "unknown argument '$1' (see --help)" ;;
esac
