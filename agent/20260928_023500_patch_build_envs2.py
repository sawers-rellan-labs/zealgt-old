# build_envs.sh: trim smoke output; --only keeps the full manifest (other envs listed as present / not_built).
p = "/Users/fvrodriguez/repos/zealgt/bin/build_envs.sh"
s = open(p).read()
s = s.replace("""smoke_out="$(echo "$smoke_out" | grep -v '^[[:space:]]*$' | head -1 | tr '\\t' ' ')\"""",
              """smoke_out="$(echo "$smoke_out" | grep -v '^[[:space:]]*$' | head -1 | tr '\\t' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')\"""")
old = """        if [ "${#only[@]}" -gt 0 ] && ! printf '%s\\n' "${only[@]}" | grep -qxF "$id"; then continue; fi"""
new = """        if [ "${#only[@]}" -gt 0 ] && ! printf '%s\\n' "${only[@]}" | grep -qxF "$id"; then
            # not selected: keep it in the manifest as it stands on disk
            if [ -f "$prefix/.zg_env_info.tsv" ]; then
                row="$(tail -1 "$prefix/.zg_env_info.tsv" | awk -F'\\t' 'BEGIN{OFS="\\t"} {$5="present"; print}')"
            else
                row="$(row "$id" "$proc" "$prefix" "$sha" "not_built" "" "" "" "" "")"
            fi
            rows="$rows"$'\\n'"$row"
            continue
        fi"""
assert old in s
s = s.replace(old, new)
open(p, "w").write(s)
