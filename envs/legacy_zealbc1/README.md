# zealbc1-era environments, snapshot 2026-09-28

Taken from `/share/maize/frodrig4/conda/env/{assembly,nilhmm,qc,nextflow}` on hazel before the user removed that folder
(script `agent/20260928_000500_snapshot_legacy_envs.sh`, read-only). They record exactly what zealbc1 ran, so zealgt's module
environments can pin the same versions and stay comparable.

Per env: `*.explicit.txt` (exact package URLs + md5, `conda create --file` can rebuild it), `*.list.txt`, `*.export.yml`,
`*.R_packages.tsv` (R library, incl. non-conda packages), `*.unowned_bin.txt` (bin/ entries no conda-meta json lists; a crude check —
the mummer / xz entries are owned by their packages through links, not hand installs).

Key versions: minibwa 0.7 (bioconda h118bc1c_0), samtools 1.21, htslib 1.21, cutadapt 4.9, bcftools 1.21 (assembly);
picard 3.5.0, multiqc 1.25.2 (qc); nextflow 26.04.6 (nextflow); r-base 4.4.3 + bcftools 1.21 (nilhmm).

Tools that are NOT conda packages (built from source; zealgt builds them with a pinned build script):
- nilHMM 0.3.0 (R package, RTIGER caller): github.com/sawers-rellan-labs/nilhmm at commit 248e67ead3693ae5af79d3cadd769e2d10b895f9,
  installed into the nilhmm env's R library.
- CRISP: github.com/vibansal/crisp at commit 1a9027ed16e6db6cf619d609806156cfc2e190fa (2026-04-21), built with `make` in
  `ZEAL/envs/crisp` (binary `bin/CRISP.binary`). The checkout shows 25 "modified" files, all file-mode only (0 lines changed; /rsstu
  ACL strips the exec bit), so it is unpatched upstream.
