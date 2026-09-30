# CRISP (vibansal/crisp, not on conda) for the CRISP module; built by .github/workflows/build_images.yml into
# ghcr.io/sawers-rellan-labs/zealgt-tools:crisp-<commit> (docs/PLAN_containers.md §2, §4). Upstream is pinned by a git clone + checkout of
# one commit + a check that HEAD is that commit (no archive: GitHub may change its bytes). Conda packages as in the module's
# former environment.yml (versions only). Two stages: compilers and git only in the build stage; the runtime image holds
# htslib (bgzip, tabix), zlib, procps (Nextflow's task metrics) and the CRISP binary, rpath'd to the same /opt/conda/lib.
ARG BASE=mambaorg/micromamba:2.3.3-debian12-slim@sha256:2237a6740d4f93f25e1f7f6f21a0d7065be6538ce153d130cef6dd9fe251d00c

FROM ${BASE} AS build
ARG CRISP_COMMIT=1a9027ed16e6db6cf619d609806156cfc2e190fa
ARG MAMBA_DOCKERFILE_ACTIVATE=1
RUN micromamba install -y -n base -c conda-forge -c bioconda --channel-priority strict \
        bioconda::htslib=1.21 conda-forge::zlib=1.3.2 conda-forge::gcc_linux-64=15.3.0 conda-forge::make=4.4.1 conda-forge::git \
    && micromamba clean -a -y
# GCC >= 14 turns the pre-C99 diagnostics into errors; upstream CRISP trips -Wint-conversion (crisp/pooledFET.c:136), which
# the older gcc of the zealbc1 build accepted as a warning: downgrade them back to warnings (same code, no source patch).
RUN git clone https://github.com/vibansal/crisp.git /tmp/crisp \
    && cd /tmp/crisp \
    && git checkout -q "${CRISP_COMMIT}" \
    && test "$(git rev-parse HEAD)" = "${CRISP_COMMIT}" \
    && make CC="${CC} -Wno-all -D_GNU_SOURCE -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=implicit-int" \
            HTSLIB_CFLAGS="-I${CONDA_PREFIX}/include" \
            HTSLIB_LIBS="-L${CONDA_PREFIX}/lib -Wl,-rpath,${CONDA_PREFIX}/lib -lhts -lz" \
    && install -m 0755 bin/CRISP.binary /tmp/CRISP

FROM ${BASE}
RUN micromamba install -y -n base -c conda-forge -c bioconda --channel-priority strict \
        bioconda::htslib=1.21 conda-forge::zlib=1.3.2 conda-forge::procps-ng \
    && micromamba clean -a -y
COPY --from=build /tmp/CRISP /opt/conda/bin/CRISP
# Nextflow and Apptainer bypass the micromamba entrypoint: put the env on PATH directly.
ENV PATH=/opt/conda/bin:${PATH}
# CRISP exits 1 on success and without arguments (modules/local/crisp/main.nf), hence the || true under pipefail
RUN ldd /opt/conda/bin/CRISP | grep -q 'libhts.so.3 => /opt/conda/lib/' && { CRISP 2>&1 || true; } | grep -q CRISP_command_line
LABEL org.opencontainers.image.source=https://github.com/sawers-rellan-labs/zealgt \
      org.opencontainers.image.description="CRISP (vibansal/crisp @ 1a9027e) with htslib 1.21 for the zealgt CRISP module"
