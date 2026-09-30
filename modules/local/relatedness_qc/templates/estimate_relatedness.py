#!/usr/bin/env python3
"""Relatedness QC of stage 2b (RELATEDNESS_QC, PLAN §3 row 2b "Relatedness QC"; VanRaden centring as zealhmm zeal_mlm_taxon.R).

Nextflow module template (modules/local/relatedness_qc/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline are
chr(9) / chr(10).

Values per sample and blind-panel site, no hard calls (PLAN: lines at 0.05-1.6x):
  --method vanraden_pseudohaploid (default): lines get one random read per covered site (x = 1 if ALT, else 0; seeded by
           --seed, drawn in site x sample-map order, so a rerun gives the same draw); BC1 pools and B73 controls get their
           ALT fraction a / (r + a).
  --method vanraden_af: every sample gets its ALT fraction.
Centring (VanRaden 2008, haploid scale): p_s = mean of x over the samples observed at s; z = x - p_s; sites with p_s in
{0, 1} carry no information and are dropped. Missing data are handled pairwise: a kinship sums only over the sites both sides
observe, k = sum z_i z_j / sum p_s (1 - p_s).
Kinship of sample i to donor group D (all samples recorded under D except i itself, every role):
  k(i, D) = sum_s z_is * mean_{j in D, j != i, observed at s} z_js / sum_s p_s (1 - p_s), over the sites where i and >= 1
  member of D are observed.
Flags (PLAN: "flagged when its kinship to its own donor's samples/lines falls outside the within-donor distribution, or when
it is closer to another donor"):
  low_kinship_own_donor  robust z of k(i, own) within its (donor, role) group below -(--flag-sd) (median / 1.4826 MAD; groups
                         with fewer than --min-group members with a value get no z);
  closer_to_other_donor  k(i, D) > k(i, own) + --closer-margin for some other donor D;
  insufficient_sites     fewer than --min-sites sites behind k(i, own): no other flag is set (not a failure).
B73 controls (no donor) get kinships to every donor group and no flag.
Outputs: <prefix>.relatedness.tsv (one row per sample), <prefix>.relatedness_donors.tsv (sample x donor group, long).
The method and the thresholds are run-card parameters (open, PLAN §3 row 2b). Standard library only.
"""
import argparse
import gzip
import json
import platform
import random
import shlex
import statistics
import sys
import logging
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("relatedness_qc")

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


def robust_z(values):
    """{key: z} by median / (1.4826 MAD); {} when the MAD is 0."""
    vals = list(values.values())
    med = statistics.median(vals)
    mad = statistics.median(abs(v - med) for v in vals) * 1.4826
    if mad <= 0:
        return {}
    return {k: (v - med) / mad for k, v in values.items()}


def main():
    ap = argparse.ArgumentParser(description="RELATEDNESS_QC options (task.ext.args)")
    ap.add_argument("--method", choices=["vanraden_pseudohaploid", "vanraden_af"], default="vanraden_pseudohaploid")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--flag-sd", type=float, default=3.0)
    ap.add_argument("--closer-margin", type=float, default=0.0)
    ap.add_argument("--min-sites", type=int, default=20)
    ap.add_argument("--min-group", type=int, default=4)
    ap.add_argument("--regions", default="")
    a = ap.parse_args(EXT_ARGS)

    panel = read_panel(PANEL, parse_regions(a.regions))
    counts, _ = read_counts(COUNTS, panel)
    role = {s: r for s, r, _ in SAMPLE_MAP}
    donor = {s: d for s, _, d in SAMPLE_MAP}
    order = [s for s, _, _ in SAMPLE_MAP]
    if len(set(order)) != len(order):
        sys.exit(f"{PROCESS}: duplicate sample ids in the sample map")

    # per-sample values x at each informative site
    rng = random.Random(a.seed)
    sites = sorted(counts)
    x = {s: {} for s in order}
    p = {}
    for si, key in enumerate(sites):
        per = counts[key]
        vals = []
        for s in order:
            if s not in per:
                continue
            r, k = per[s]
            if role[s] == "line" and a.method == "vanraden_pseudohaploid":
                v = 1.0 if rng.random() < k / (r + k) else 0.0
            else:
                v = k / (r + k)
            x[s][si] = v
            vals.append(v)
        if not vals:
            continue  # no mapped sample has reads here: not a site for the allele frequency
        p[si] = sum(vals) / len(vals)
    informative = {si for si, ps in p.items() if 0.0 < ps < 1.0}
    w = {si: p[si] * (1.0 - p[si]) for si in informative}
    z = {s: {si: v - p[si] for si, v in xs.items() if si in informative} for s, xs in x.items()}

    donors = sorted({d for d in donor.values() if d})
    members = {d: [s for s in order if donor[s] == d] for d in donors}
    gsum = {d: {} for d in donors}
    gcnt = {d: {} for d in donors}
    for d in donors:
        for s in members[d]:
            for si, v in z[s].items():
                gsum[d][si] = gsum[d].get(si, 0.0) + v
                gcnt[d][si] = gcnt[d].get(si, 0) + 1

    kin = {}  # (sample, donor) -> (k, n_sites)
    for s in order:
        for d in donors:
            own = donor[s] == d
            num = den = 0.0
            n = 0
            for si, v in z[s].items():
                c = gcnt[d].get(si, 0) - (1 if own else 0)
                if c <= 0:
                    continue
                m = (gsum[d][si] - (v if own else 0.0)) / c
                num += v * m
                den += w[si]
                n += 1
            kin[(s, d)] = (num / den if den > 0 else None, n)

    # robust z of the own-donor kinship within each (donor, role) group
    zscore = {}
    groups = {}
    for s in order:
        if donor[s]:
            k, n = kin[(s, donor[s])]
            if k is not None and n >= a.min_sites:
                groups.setdefault((donor[s], role[s]), {})[s] = k
    for g, vals in groups.items():
        if len(vals) >= a.min_group:
            zscore.update(robust_z(vals))

    n_flag = 0
    with open(f"{PREFIX}.relatedness.tsv", "w") as out:
        out.write(TAB.join(["sample", "role", "donor", "method", "n_sites", "kinship_self", "kinship_own", "n_sites_own",
                            "own_z", "closest_other_donor", "kinship_closest_other", "n_sites_closest_other", "flag",
                            "reason"]) + NL)
        for s in order:
            den = sum(w[si] for si in z[s])
            kself = sum(v * v for v in z[s].values()) / den if den > 0 else None
            d0 = donor[s]
            kown, nown = kin[(s, d0)] if d0 else (None, 0)
            others = [(kin[(s, d)][0], d) for d in donors if d != d0 and kin[(s, d)][0] is not None]
            best = max(others) if others else (None, ".")
            reasons = []
            if d0:
                if kown is None or nown < a.min_sites:
                    reasons.append("insufficient_sites")
                else:
                    zs = zscore.get(s)
                    if zs is not None and zs < -a.flag_sd:
                        reasons.append("low_kinship_own_donor")
                    if best[0] is not None and best[0] > kown + a.closer_margin:
                        reasons.append("closer_to_other_donor")
            flag = any(r != "insufficient_sites" for r in reasons)
            n_flag += flag
            out.write(TAB.join([s, role[s], d0 or ".", a.method, str(len(z[s])), fmt(kself), fmt(kown), str(nown),
                                fmt(zscore.get(s), 3), best[1], fmt(best[0]),
                                str(kin[(s, best[1])][1]) if best[1] != "." else "0", str(flag).lower(),
                                ",".join(reasons) or "."]) + NL)
    with open(f"{PREFIX}.relatedness_donors.tsv", "w") as out:
        out.write(TAB.join(["sample", "role", "donor", "donor_group", "kinship", "n_sites"]) + NL)
        for s in order:
            for d in donors:
                k, n = kin[(s, d)]
                out.write(TAB.join([s, role[s], donor[s] or ".", d, fmt(k), str(n)]) + NL)
    LOG.info(f"relatedness_qc {PREFIX}: {len(order)} samples, {len(donors)} donors, {len(informative)} informative of "
          f"{len(panel)} panel sites, method {a.method}, seed {a.seed}, {n_flag} flagged")
    with open(f"{PREFIX}.relatedness_qc.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
