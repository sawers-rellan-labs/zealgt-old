#!/usr/bin/env python3
"""Donor-content QC of stage 2b (DONOR_CONTENT_QC, PLAN §3 row 2b "Donor-content QC").

Nextflow module template (modules/local/donor_content_qc/main.nf): the Groovy placeholders are filled in by Nextflow, so the
task hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline
are chr(9) / chr(10).

Per sample, over the blind-panel sites it covers (>= 1 read): the share of sites with >= 1 ALT read (share_sites_alt) and the
ALT read fraction (alt_reads / reads, alt_read_fraction; less dependent on depth). Catches B73 contamination (selfing, seed
mix-up), which kinship alone does not separate from a line that carries little donor genome. Expectations: --expected
(params.donor_content_expected, 0.125, BC2S3 lines), --expected-bc1 (0.25, a BC1 plant carries one F1 gamete), 0 for B73
controls. Both statistics are also given relative to the median of the sample's (donor, role) group (rel_to_group): the
absolute value scales with the share of panel sites at which the donor carries the ALT allele, the relative one does not.
Flags (--statistic picks alt_read_fraction (default) or share_sites_alt):
  low_donor_content      line / BC1 pool below --flag-low (params.donor_content_flag_low, 0.03);
  low_relative_to_group  rel_to_group below --flag-relative (default 0 = off);
  donor_alleles_in_b73   B73 control above --flag-high-b73 (default 0.03);
  insufficient_sites     fewer than --min-sites covered panel sites: no other flag (not a failure).
Output <prefix>.donor_content.tsv. Standard library only.
"""
import argparse
import gzip
import json
import platform
import shlex
import statistics
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("donor_content_qc")

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


def fmt(v, nd=6):
    return "NA" if v is None else f"{v:.{nd}f}"


def main():
    ap = argparse.ArgumentParser(description="DONOR_CONTENT_QC options (task.ext.args)")
    ap.add_argument("--expected", type=float, default=0.125)
    ap.add_argument("--expected-bc1", type=float, default=0.25)
    ap.add_argument("--statistic", choices=["alt_read_fraction", "share_sites_alt"], default="alt_read_fraction")
    ap.add_argument("--flag-low", type=float, default=0.03)
    ap.add_argument("--flag-relative", type=float, default=0.0)
    ap.add_argument("--flag-high-b73", type=float, default=0.03)
    ap.add_argument("--min-sites", type=int, default=20)
    ap.add_argument("--regions", default="")
    a = ap.parse_args(EXT_ARGS)

    panel = read_panel(PANEL, parse_regions(a.regions))
    counts, _ = read_counts(COUNTS, panel)
    order = [s for s, _, _ in SAMPLE_MAP]
    if len(set(order)) != len(order):
        sys.exit(f"{PROCESS}: duplicate sample ids in the sample map")
    tot = {s: [0, 0, 0, 0] for s in order}  # covered sites, sites with ALT, reads, ALT reads
    for per in counts.values():
        for s, (r, k) in per.items():
            if s in tot:
                t = tot[s]
                t[0] += 1
                t[1] += k > 0
                t[2] += r + k
                t[3] += k
    stat = {}
    share = {}
    arf = {}
    for s in order:
        cov, nalt, reads, alt = tot[s]
        share[s] = nalt / cov if cov else None
        arf[s] = alt / reads if reads else None
        stat[s] = arf[s] if a.statistic == "alt_read_fraction" else share[s]
    group = {}
    for s, role, donor in SAMPLE_MAP:
        if stat[s] is not None and tot[s][0] >= a.min_sites:
            group.setdefault((donor, role), []).append(stat[s])
    med = {g: statistics.median(v) for g, v in group.items()}

    n_flag = 0
    with open(f"{PREFIX}.donor_content.tsv", "w") as out:
        out.write(TAB.join(["sample", "role", "donor", "covered_sites", "sites_with_alt", "share_sites_alt", "reads",
                            "alt_reads", "alt_read_fraction", "expected", "ratio_to_expected", "statistic",
                            "rel_to_group", "flag", "reason"]) + NL)
        for s, role, donor in SAMPLE_MAP:
            cov, nalt, reads, alt = tot[s]
            exp = a.expected if role == "line" else a.expected_bc1 if role == "bc1_sample" else 0.0
            m = med.get((donor, role))
            rel = stat[s] / m if stat[s] is not None and m else None
            reasons = []
            if cov < a.min_sites or stat[s] is None:
                reasons.append("insufficient_sites")
            elif role == "b73_control":
                if stat[s] > a.flag_high_b73:
                    reasons.append("donor_alleles_in_b73")
            else:
                if stat[s] < a.flag_low:
                    reasons.append("low_donor_content")
                if rel is not None and rel < a.flag_relative:
                    reasons.append("low_relative_to_group")
            flag = any(r != "insufficient_sites" for r in reasons)
            n_flag += flag
            ratio = arf[s] / exp if arf[s] is not None and exp > 0 else None
            out.write(TAB.join([s, role, donor or ".", str(cov), str(nalt), fmt(share[s]), str(reads), str(alt),
                                fmt(arf[s]), f"{exp:g}", fmt(ratio, 4), a.statistic, fmt(rel, 4), str(flag).lower(),
                                ",".join(reasons) or "."]) + NL)
    LOG.info(f"donor_content_qc {PREFIX}: {len(order)} samples, {len(panel)} panel sites, statistic {a.statistic}, "
          f"{n_flag} flagged")
    with open(f"{PREFIX}.donor_content_qc.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
