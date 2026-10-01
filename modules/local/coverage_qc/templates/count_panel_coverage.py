#!/usr/bin/env python3
"""Panel coverage QC of stage 2b (COVERAGE_QC, PLAN §3 row 2b "Coverage QC", as zealhmm scripts/zeal_paired_cohort_coverage_qc.R).

Nextflow module template (modules/local/coverage_qc/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline are
chr(9) / chr(10).

Inputs: the blind QC panel (chrom pos [ref alt], no header needed), the QC_PANEL_COUNTS tables (ALLELE_COUNTS output:
`bcftools query -H -f '%CHROM %POS %REF %ALT [%AD]'`, bgzipped, one column per sample named by its SM) and the sample map
[sample, role, donor]. A covered marker is a panel site with >= 1 read (REF + panel ALT; all non-REF reads when the panel
has no ALT column). Per sample x panel contig, <prefix>.panel_coverage.tsv:
  sample role donor contig n_sites covered covered_frac reads mean_depth counted below_min_markers below_<k>...
n_sites = panel sites on the contig inside --regions (whole contig when not given). counted = the sample has a column in a
count table (else every count is 0). below_min_markers uses --min-markers (params.panel_min_markers, 2 x rigidity); the
--report-at thresholds (default 10,100) are reported alongside, as zealhmm does. This table REPORTS; the exclusion of lines
by covered markers is applied in ancestry_inference on the donor's own tier-A sites (LINE_MARKER_QC; design §10 item 5).
Indel records are skipped (REF longer than one base). Standard library only.
"""
import argparse
import gzip
import json
import platform
import shlex
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("coverage_qc")

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
COUNTS = sorted("${counts}".split())
PANEL = "${panel}"
SAMPLE_MAP = json.loads('''${groovy.json.JsonOutput.toJson(sample_map)}''')  # [[sample, role, donor], ...]
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')


# ---- shared panel / count-table readers (same code in coverage_qc, relatedness_qc, donor_content_qc) -------------------
def parse_regions(text):
    """'chr10,chr2:1-500' -> {contig: [(start, end), ...]} (1-based, inclusive; None = whole contig)."""
    out = {}
    for tok in (text or "").split(","):
        tok = tok.strip()
        if not tok:
            continue
        if ":" in tok:
            c, rng = tok.rsplit(":", 1)
            a, b = rng.replace("_", "").split("-")
            out.setdefault(c, []).append((int(a), int(b)))
        else:
            out.setdefault(tok, []).append(None)
    return out


def in_regions(regions, chrom, pos):
    if not regions:
        return True
    for r in regions.get(chrom, []):
        if r is None or r[0] <= pos <= r[1]:
            return True
    return False


def read_panel(path, regions):
    """Panel sites {(chrom, pos): (ref, alt)}; ref / alt are None when the panel has positions only."""
    sites = {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as fh:
        for ln in fh:
            x = ln.rstrip(NL).split(TAB)
            if len(x) < 2 or ln.startswith("#"):
                continue
            try:
                pos = int(x[1])
            except ValueError:
                continue  # a header line
            if not in_regions(regions, x[0], pos):
                continue
            ref = x[2].upper() if len(x) > 2 and x[2] not in ("", ".") else None
            alt = x[3].upper() if len(x) > 3 and x[3] not in ("", ".") else None
            sites[(x[0], pos)] = (ref, alt)
    return sites


def sample_of(token):
    """bcftools query -H column '[5]S1:AD' -> 'S1'."""
    t = token.strip()
    if t.startswith("#"):
        t = t[1:].strip()
    if t.startswith("[") and "]" in t:
        t = t.split("]", 1)[1]
    if t.endswith(":AD"):
        t = t[:-3]
    return t


def read_counts(paths, panel):
    """{(chrom, pos): {sample: (ref_reads, alt_reads)}} at panel sites, plus the sample list (first table wins when a sample
    is in several tables). ALT reads = AD of the panel ALT allele (0 if mpileup did not list it), or every non-REF read when
    the panel has no ALT."""
    counts = {}
    samples = []
    seen = set()
    for path in paths:
        opener = gzip.open if path.endswith(".gz") else open
        cols = None
        keep = []
        with opener(path, "rt") as fh:
            for ln in fh:
                x = ln.rstrip(NL).split(TAB)
                if ln.startswith("#"):
                    cols = [sample_of(t) for t in x[4:]]
                    keep = []
                    for i, s in enumerate(cols):
                        if s in seen:
                            LOG.info(f"{PROCESS}: sample {s} is in more than one count table; first one kept ({path} skipped)")
                        else:
                            keep.append(i)
                            seen.add(s)
                            samples.append(s)
                    continue
                if cols is None:
                    sys.exit(f"{PROCESS}: {path} has no bcftools query -H header line")
                if len(x) != 4 + len(cols):
                    sys.exit(f"{PROCESS}: {path}: {len(x) - 4} AD columns vs {len(cols)} samples")
                key = (x[0], int(x[1]))
                if key not in panel or len(x[2]) != 1:
                    continue
                pref, palt = panel[key]
                if pref is not None and pref != x[2].upper():
                    continue
                alts = [] if x[3] == "." else x[3].upper().split(",")
                ai = alts.index(palt) + 1 if palt is not None and palt in alts else None
                site = counts.setdefault(key, {})
                for i in keep:
                    ad = x[4 + i]
                    if ad in (".", ""):
                        continue
                    v = [int(t) if t not in (".", "") else 0 for t in ad.split(",")]
                    if palt is None:
                        a = sum(v[1:])
                    else:
                        a = v[ai] if ai is not None and ai < len(v) else 0
                    if v[0] + a > 0:
                        site[cols[i]] = (v[0], a)
    return counts, samples
# ---- end of shared readers ----------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="COVERAGE_QC options (task.ext.args)")
    ap.add_argument("--min-markers", type=int, default=1000)
    ap.add_argument("--report-at", default="10,100")
    ap.add_argument("--regions", default="")
    a = ap.parse_args(EXT_ARGS)
    report_at = [int(t) for t in a.report_at.split(",") if t.strip()]

    regions = parse_regions(a.regions)
    panel = read_panel(PANEL, regions)
    counts, counted = read_counts(COUNTS, panel)
    counted = set(counted)
    contigs = []
    n_sites = {}
    for c, _ in panel:
        if c not in n_sites:
            contigs.append(c)
            n_sites[c] = 0
        n_sites[c] += 1
    cov = {}
    reads = {}
    for (c, _), per in counts.items():
        for s, (r, k) in per.items():
            cov[(s, c)] = cov.get((s, c), 0) + 1
            reads[(s, c)] = reads.get((s, c), 0) + r + k

    hdr = ["sample", "role", "donor", "contig", "n_sites", "covered", "covered_frac", "reads", "mean_depth", "counted",
           "below_min_markers"] + [f"below_{k}" for k in report_at]
    n_low = 0
    with open(f"{PREFIX}.panel_coverage.tsv", "w") as out:
        out.write(TAB.join(hdr) + NL)
        for s, role, donor in SAMPLE_MAP:
            low = False
            for c in contigs:
                n = n_sites[c]
                k = cov.get((s, c), 0)
                d = reads.get((s, c), 0)
                below = k < a.min_markers
                low = low or below
                row = [s, role, donor or ".", c, n, k, f"{k / n:.6f}" if n else "NA", d, f"{d / n:.6f}" if n else "NA",
                       str(s in counted).lower(), str(below).lower()] + [str(k < t).lower() for t in report_at]
                out.write(TAB.join(str(v) for v in row) + NL)
            n_low += low
    LOG.info(f"coverage_qc {PREFIX}: {len(SAMPLE_MAP)} samples, {len(panel)} panel sites on {len(contigs)} contigs, "
          f"{n_low} samples with a contig below {a.min_markers} covered markers")
    with open(f"{PREFIX}.coverage_qc.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
