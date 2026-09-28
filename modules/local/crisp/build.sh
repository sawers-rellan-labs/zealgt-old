#!/usr/bin/env bash
# Builds CRISP from a pinned commit into $CONDA_PREFIX/bin/CRISP (scripts/build_envs.sh runs this inside the new env, xfer node).
# zg-source: https://github.com/vibansal/crisp@1a9027ed16e6db6cf619d609806156cfc2e190fa
set -eo pipefail
: "${CONDA_PREFIX:?}" "${ZG_BUILD_DIR:?}"
commit=1a9027ed16e6db6cf619d609806156cfc2e190fa
sha256=60c3a14497fdab35d0ac663a7c08f0f99261e2a95048d665999a92e65110e642
cd "$ZG_BUILD_DIR"
curl -fsSL -o crisp.tar.gz "https://github.com/vibansal/crisp/archive/${commit}.tar.gz"
echo "${sha256}  crisp.tar.gz" | sha256sum -c -
tar -xzf crisp.tar.gz
cd "crisp-${commit}"
# Makefile: CC=gcc, HTSLIB_* from pkg-config or "-lhts -lz"; point both at the env's htslib (conda compiler $CC) and rpath it
make CC="${CC:?conda compiler not activated} -Wno-all -D_GNU_SOURCE" HTSLIB_CFLAGS="-I$CONDA_PREFIX/include" \
     HTSLIB_LIBS="-L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib -lhts -lz"
install -m 0755 bin/CRISP.binary "$CONDA_PREFIX/bin/CRISP"
"$CONDA_PREFIX/bin/CRISP" 2>&1 | head -3 || true
