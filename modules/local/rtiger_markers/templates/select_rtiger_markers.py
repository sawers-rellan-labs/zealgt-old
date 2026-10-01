#!/usr/bin/env python3
"""RTIGER marker selection of stage 4 (RTIGER_MARKERS, design §2.3; zealbc1 rtiger_ancestry_inference.sbatch: the donor's own
tier-A sites).

Nextflow module template (modules/local/rtiger_markers/main.nf): the Groovy placeholders are filled in by Nextflow, so the
task hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline
are chr(9) / chr(10).

Reads the donor's step-4 table (<donor>.<region>.sites.tsv.gz, POOLED_LIKELIHOOD_TIERS; columns found by header name: chrom,
pos, ref, alt, tier, flags) and writes <prefix>.tierA_sites.tsv: chrom pos ref alt, tab-separated, NO header (it is the
ALLELE_COUNTS site list: `cut -f1,2 | sort` feeds `bcftools mpileup -T`), sorted by contig (order of first appearance) and
position. Kept: tier == A (--tier), single-base ACGT REF and ALT, REF != ALT, and no flag listed in --exclude-flags (default
hidepth,af_gt_half,inconsistent: tier A already excludes them in the zealbc1 rule; the check keeps the markers clean if a
tier rule changes). A position with more than one kept allele is multiallelic and dropped entirely. Summary counts go to
<prefix>.rtiger_markers.tsv (one row). Standard library only.
"""
import argparse
import gzip
import platform
import shlex
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("rtiger_markers")

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
SITES = "${sites}"
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')
BASES = set("ACGT")


def main():
    ap = argparse.ArgumentParser(description="RTIGER_MARKERS options (task.ext.args)")
    ap.add_argument("--tier", default="A")
    ap.add_argument("--exclude-flags", default="hidepth,af_gt_half,inconsistent")
    a = ap.parse_args(EXT_ARGS)
    exclude = {f for f in a.exclude_flags.split(",") if f}

    opener = gzip.open if SITES.endswith(".gz") else open
    n = {"rows": 0, "tier": 0, "not_snv": 0, "flagged": 0, "multiallelic_positions": 0}
    kept = {}
    contigs = []
    with opener(SITES, "rt") as fh:
        hdr = fh.readline().rstrip(NL).split(TAB)
        try:
            ic, ip, ir, ia, it = (hdr.index(k) for k in ("chrom", "pos", "ref", "alt", "tier"))
        except ValueError:
            sys.exit(f"{PROCESS}: {SITES} lacks one of the columns chrom pos ref alt tier (header: {hdr})")
        ifl = hdr.index("flags") if "flags" in hdr else None
        for ln in fh:
            x = ln.rstrip(NL).split(TAB)
            if len(x) < len(hdr):
                continue
            n["rows"] += 1
            if x[it] != a.tier:
                continue
            n["tier"] += 1
            ref, alt = x[ir].upper(), x[ia].upper()
            if len(ref) != 1 or len(alt) != 1 or ref not in BASES or alt not in BASES or ref == alt:
                n["not_snv"] += 1
                continue
            flags = set(x[ifl].split(",")) if ifl is not None else set()
            if flags & exclude:
                n["flagged"] += 1
                continue
            key = (x[ic], int(x[ip]))
            if x[ic] not in contigs:
                contigs.append(x[ic])
            kept.setdefault(key, set()).add((ref, alt))
    rank = {c: i for i, c in enumerate(contigs)}
    out_rows = []
    for key in sorted(kept, key=lambda k: (rank[k[0]], k[1])):
        alleles = kept[key]
        if len(alleles) > 1:
            n["multiallelic_positions"] += 1
            continue
        ref, alt = next(iter(alleles))
        out_rows.append((key[0], key[1], ref, alt))
    with open(f"{PREFIX}.tierA_sites.tsv", "w") as out:
        for c, p, r, t in out_rows:
            out.write(f"{c}{TAB}{p}{TAB}{r}{TAB}{t}{NL}")
    with open(f"{PREFIX}.rtiger_markers.tsv", "w") as out:
        cols = ["id", "rows", "tier", "tier_rows", "not_snv", "flagged", "multiallelic_positions", "markers"]
        out.write(TAB.join(cols) + NL)
        out.write(TAB.join(str(v) for v in [PREFIX, n["rows"], a.tier, n["tier"], n["not_snv"], n["flagged"],
                                             n["multiallelic_positions"], len(out_rows)]) + NL)
    LOG.info(f"rtiger_markers {PREFIX}: {len(out_rows)} markers from {n['tier']} tier-{a.tier} rows of {n['rows']}")
    if not out_rows:
        LOG.warning(f"rtiger_markers {PREFIX}: no tier-{a.tier} marker; RTIGER will have no input")
    with open(f"{PREFIX}.rtiger_markers.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
