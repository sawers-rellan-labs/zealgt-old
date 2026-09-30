#!/usr/bin/env bash
# Installs the nilHMM R package (Julia-free RTIGER port) from a pinned commit into this env's R library
# ($CONDA_PREFIX/lib/R/library); scripts/build_envs.sh runs this inside the new env, xfer node. Its R deps (Rcpp,
# RcppParallel) and the compilers are pinned in environment.yml, so R CMD INSTALL downloads nothing else.
# zg-source: https://github.com/sawers-rellan-labs/nilhmm@248e67ead3693ae5af79d3cadd769e2d10b895f9
set -eo pipefail
: "${CONDA_PREFIX:?}" "${ZG_BUILD_DIR:?}"
commit=248e67ead3693ae5af79d3cadd769e2d10b895f9
sha256=6e089729a07c3b598477006ee7f31d702a93d58958211b9f0d94c937ede17ad5
cd "$ZG_BUILD_DIR"
curl -fsSL -o nilhmm.tar.gz "https://github.com/sawers-rellan-labs/nilhmm/archive/${commit}.tar.gz"
echo "${sha256}  nilhmm.tar.gz" | sha256sum -c -
tar -xzf nilhmm.tar.gz
cd "nilhmm-${commit}"
R CMD INSTALL --no-test-load --library="$CONDA_PREFIX/lib/R/library" .
Rscript -e 'stopifnot(packageVersion("nilHMM") == "0.3.0"); suppressPackageStartupMessages(library(nilHMM)); cat("nilHMM", as.character(packageVersion("nilHMM")), "\n")'
