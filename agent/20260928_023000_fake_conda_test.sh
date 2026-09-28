#!/usr/bin/env bash
# Dry test of bin/build_envs.sh's build path with a fake conda binary (laptop has no conda): build, skip, stale prefix.
S=/private/tmp/claude-502/-Users-fvrodriguez-repos-zealgt/b6a7b37e-4c9c-4f0c-94ff-8207aaff1b4e/scratchpad/fakeconda
mkdir -p "$S"
cat > "$S/conda" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --version) echo "conda 0.0-fake";;
  env) p="$4"; f="$6"; mkdir -p "$p/bin" "$p/conda-meta"; cp "$f" "$p/conda-meta/env.yml"; echo "fake create $p";;
  list) p="$3"; bash /Users/fvrodriguez/repos/zealgt/bin/build_envs.sh --deps "$p/conda-meta/env.yml" | awk -F'\t' '{b=$3; if(b=="") b="h0"; print $1"="$2"="b}';;
  run) shift; p="$2"; shift 2; [ "$1" = "--no-capture-output" ] && shift; CONDA_PREFIX="$p" PATH="$p/bin:/Users/fvrodriguez/repos/zealgt/agent/bin:$PATH" NXF_VER=26.04.6 "$@";;
esac
FAKE
chmod +x "$S/conda"
export ZG_ALLOW_STALE_CONFIG=1 ZG_CONDA="$S/conda" ZG_ENV_ROOT="$S/root2" CONDA_PKGS_DIRS="$S/pkgs"
B=/Users/fvrodriguez/repos/zealgt/bin/build_envs.sh
echo "### first build (fastqc smoke will fail: no binary in fake env)"; bash "$B"; echo "rc=$?"; cat "$ZG_ENV_ROOT/manifest.tsv"
echo "### second build (skips + stale prefix for fastqc)"; bash "$B"; echo "rc=$?"; cut -f1,5 "$ZG_ENV_ROOT/manifest.tsv"
echo "### --only nextflow"; bash "$B" --only nextflow; echo "rc=$?"
ls "$ZG_ENV_ROOT"/nextflow-*/share/nextflow/plugins
