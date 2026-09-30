# nilHMM (sawers-rellan-labs/nilhmm, not on CRAN / conda yet) for the RTIGER module; built by .github/workflows/build_images.yml
# into ghcr.io/sawers-rellan-labs/zealgt-tools:nilhmm-<version> (docs/PLAN_containers.md §2, §4). R, every R dependency and the compilers come
# from conda-forge (the packages of the module's former environment.yml, versions only; conda-forge's r-base depends on its
# compilers anyway, so a compiler-free stage would save nothing); nilHMM alone is installed on top, from the tagged release
# archive (tag v0.3.1 -> commit 6e9b408, the code of the benchmark's 248e67e), checked by sha256. procps: Nextflow's task metrics.
FROM mambaorg/micromamba:2.3.3-debian12-slim@sha256:2237a6740d4f93f25e1f7f6f21a0d7065be6538ce153d130cef6dd9fe251d00c

ARG NILHMM_TAG=v0.3.1
ARG NILHMM_SHA256=d9b5826afb9af7efd5e596e0d74bbf41c3194bad6f6da844ea48fea8d20ef7a0
ARG MAMBA_DOCKERFILE_ACTIVATE=1

RUN micromamba install -y -n base -c conda-forge --channel-priority strict \
        conda-forge::r-base=4.4.3 conda-forge::r-data.table=1.18.6.1 conda-forge::r-rcpp=1.1.2 \
        conda-forge::r-rcppparallel=5.1.11_2 conda-forge::gcc_linux-64=15.3.0 conda-forge::gxx_linux-64=15.3.0 \
        conda-forge::make=4.4.1 conda-forge::curl conda-forge::procps-ng \
    && micromamba clean -a -y

RUN cd /tmp \
    && curl -fsSL -o nilhmm.tar.gz "https://github.com/sawers-rellan-labs/nilhmm/archive/refs/tags/${NILHMM_TAG}.tar.gz" \
    && echo "${NILHMM_SHA256}  nilhmm.tar.gz" | sha256sum -c - \
    && tar -xzf nilhmm.tar.gz \
    && R CMD INSTALL --library=/opt/conda/lib/R/library "nilhmm-${NILHMM_TAG#v}" \
    && rm -rf /tmp/nilhmm.tar.gz "/tmp/nilhmm-${NILHMM_TAG#v}"

# Nextflow and Apptainer bypass the micromamba entrypoint: put the env on PATH directly.
ENV PATH=/opt/conda/bin:${PATH}
RUN Rscript -e 'stopifnot(packageVersion("nilHMM") == "0.3.1"); suppressPackageStartupMessages({library(nilHMM); library(data.table)}); cat("nilHMM", as.character(packageVersion("nilHMM")), "\n")'
LABEL org.opencontainers.image.source=https://github.com/sawers-rellan-labs/zealgt \
      org.opencontainers.image.description="nilHMM v0.3.1 (R 4.4.3, conda-forge deps) for the zealgt RTIGER module"
