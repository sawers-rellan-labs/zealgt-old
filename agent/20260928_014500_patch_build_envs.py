# Patch bin/build_envs.sh: failure rows in the manifest, robust yml dep parsing, smoke_cmd field split.
p = "/Users/fvrodriguez/repos/zealgt/bin/build_envs.sh"
s = open(p).read()

old_yml = s[s.index("yml_deps() {"):s.index("# verify_pins")]
new_yml = r'''yml_deps() {
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
        }' "$1"
}

'''
s = s.replace(old_yml, new_yml)

s = s.replace('''    awk -F'\\t' -v id="$1" '$1==id { $1=""; sub(/^\\t?/, ""); print; exit }' "$REPO/envs/smoke_tests.tsv"''',
              '''    awk -F'\\t' -v id="$1" '$1==id { print substr($0, index($0, "\\t") + 1); exit }' "$REPO/envs/smoke_tests.tsv"''')

old_b = s[s.index("build_one() {"):s.index("MANIFEST_HEADER=")]
new_b = r'''# manifest row: module process prefix sha8 status sources tool_versions n_files built_at conda
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

build_one() {
    local id="$1" proc="$2" rel="$3" sha="$4" prefix="$5"
    local dir="$REPO/$rel" info="$prefix/.zg_env_info.tsv" sources pins smoke smoke_out nfiles cv
    cv="$("$ZG_CONDA" --version 2>&1)"
    sources="$(grep -hoE '^# zg-source: .*' "$dir/build.sh" 2>/dev/null | sed 's/^# zg-source: //' | paste -sd, - || true)"
    fail() { log "FAILED $id: $1"; row "$id" "$proc" "$prefix" "$sha" "failed_$2" "$sources" "" "" "$(date '+%F %T')" "$cv"; return 1; }
    if [ -f "$info" ]; then
        log "skip $id: $prefix exists (built $(tail -1 "$info" | cut -f9))"
        tail -1 "$info" | awk -F'\t' 'BEGIN{OFS="\t"} {$5="skipped_exists"; print}'
        return 0
    fi
    if [ -e "$prefix" ]; then
        fail "$prefix exists without .zg_env_info.tsv (an earlier build failed); left untouched, remove it by hand" stale_prefix
        return 1
    fi
    log "build $id -> $prefix"
    "$ZG_CONDA" env create -p "$prefix" -f "$dir/environment.yml" >&2 || { fail "conda env create" create; return 1; }
    if [ -f "$dir/build.sh" ]; then
        local bdir="$prefix/share/zg_build"
        mkdir -p "$bdir"
        log "build.sh for $id (sources: ${sources:-none declared})"
        ZG_ENV_DIR="$dir" ZG_BUILD_DIR="$bdir" "$ZG_CONDA" run -p "$prefix" --no-capture-output bash "$dir/build.sh" >&2 \
            || { fail "build.sh" build_sh; return 1; }
    fi
    pins="$(verify_pins "$prefix" "$dir/environment.yml")" || { fail "pinned packages not as specified" pins; return 1; }
    smoke="$(smoke_cmd "$id")"
    smoke_out="pins_ok"
    if [ -n "$smoke" ]; then
        smoke_out="$("$ZG_CONDA" run -p "$prefix" bash -c "$smoke" 2>&1)" || { fail "smoke test '$smoke': $smoke_out" smoke; return 1; }
        smoke_out="$(echo "$smoke_out" | grep -v '^[[:space:]]*$' | head -1 | tr '\t' ' ')"
    fi
    nfiles="$(find "$prefix" | wc -l | tr -d ' ')"
    row "$id" "$proc" "$prefix" "$sha" "built" "$sources" "$smoke_out | $pins" "$nfiles" "$(date '+%F %T')" "$cv" | tee "$info"
    log "ok $id ($nfiles files): $smoke_out"
}

'''
s = s.replace(old_b, new_b)
open(p, "w").write(s)
