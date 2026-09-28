#!/usr/bin/env python3
"""Reporting tables of one donor x region (GENOTYPE_SUMMARY, stage 8; PLAN §3 row 8, §4 #12; math supplement Text "checks";
design §2.7, review #12).

Nextflow module template (modules/local/genotype_summary/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_summarize_genotypes.py). Standard library only.

Expectation (--expectation, PLAN §4 #12: the bulk's parent BC2S2 is the expectation):
  bc2s2  x = 0 / 1 / 2 : 27/32, 1/16, 3/32        bc2s3  55/64, 1/32, 7/64        (donor allele frequency 1/8 in both)
Outputs
  <prefix>.genotype_summary.tsv   per line (+ row ALL): RTIGER Mb in x = 0 / 1 / 2 over bp (called Mb = inside a segment),
                                  their fractions and the expectation, and at the union sites the raster counts gt 0 / 1 / 2 /
                                  NA with the no-call share; excluded lines are listed with excluded = true
  <prefix>.single_locus.tsv       per non-multiallelic site: D, call_step, lines with known x, counts x = 0 / 1 / 2, donor
                                  segment frequency (sum x / 2n) and allele frequency from gt vs 1/8, HET and x = 2 frequency
                                  vs the expectation, chi-square (2 df) of the x counts against it and its p-value
  <prefix>.breakpoint_density.tsv review #12: per line (+ ALL), the gap sites within --breakpoint-window own tier-A markers of a
                                  RTIGER breakpoint of that line vs elsewhere, and the share of step-2 calls in each
  <prefix>.genotype_summary.versions.yml
Markers = the donor's own tier-A sites (call_step own); a breakpoint = the midpoint between consecutive segments of a line
with different states.
"""
import argparse
import bisect
import csv
import gzip
import math
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)
NA = "NA"
DOT = "."
EXPECT = {"bc2s2": (27 / 32, 1 / 16, 3 / 32), "bc2s3": (55 / 64, 1 / 32, 7 / 64)}


def log(msg):
    sys.stderr.write("[genotype_summary] " + msg + NL)


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def opt_path(s):
    s = s.strip()
    return "" if s in ("", "[]") else s


def fmt(x):
    if x is None:
        return NA
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, float):
        return NA if x != x else f"{x:.6g}"
    return str(x)


def num(s):
    return None if s in (NA, DOT, "") else int(s)


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="summarize_genotypes.py")
    ap.add_argument("--expectation", choices=sorted(EXPECT), default="bc2s2")
    ap.add_argument("--breakpoint-window", type=int, default=500)
    return ap.parse_args(argv)


def read_segments(path):
    """{line: sorted [(start, end, state)]} (CSV or TSV)."""
    seg = {}
    if not path:
        return seg
    with open_text(path) as fh:
        head = fh.readline()
        delim = TAB if TAB in head else ","
        cols = [c.strip().strip('"') for c in head.rstrip(NL).split(delim)]
        for line in fh:
            x = [v.strip().strip('"') for v in line.rstrip(NL).split(delim)]
            if len(x) < len(cols):
                continue
            r = dict(zip(cols, x))
            seg.setdefault(r["name"], []).append((int(float(r["start_bp"])), int(float(r["end_bp"])), int(float(r["state"]))))
    return {k: sorted(v) for k, v in seg.items()}


def read_line_qc(path):
    """{sample: line_pass} from LINE_MARKER_QC's line_qc.tsv: columns sample and line_pass (true|false), one row per contig."""
    out = {}
    if not path:
        return out
    with open_text(path) as fh:
        rd = csv.DictReader(fh, delimiter=TAB)
        cols = rd.fieldnames or []
        if "sample" not in cols or "line_pass" not in cols:
            raise SystemExit(f"GENOTYPE_SUMMARY: line_qc {path} needs the LINE_MARKER_QC columns sample and line_pass, has {cols}")
        for r in rd:
            v = r["line_pass"].strip().lower()
            if v not in ("true", "false"):
                raise SystemExit(f"GENOTYPE_SUMMARY: line_qc {path}: line_pass of {r['sample']} is {r['line_pass']!r}, not true/false")
            if out.setdefault(r["sample"], v == "true") != (v == "true"):
                raise SystemExit(f"GENOTYPE_SUMMARY: line_qc {path}: line_pass of {r['sample']} differs between its contig rows")
    return out


def read_alleles(path):
    rows = []
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            rows.append({"key": (r["chrom"], int(r["pos"]), r["ref"], r["alt"]), "D": r["D"], "call_step": r["call_step"]})
    return rows


def read_genotypes(path):
    """{line: {key: (x, gt)}} of the raster long table."""
    g = {}
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            g.setdefault(r["line"], {})[(r["chrom"], int(r["pos"]), r["ref"], r["alt"])] = (num(r["x"]), num(r["gt"]))
    return g


def line_summary(seg, geno, qc, expect):
    lines = sorted(set(seg) | set(geno) | set(qc))
    rows = []
    tot = {"mb": [0.0, 0.0, 0.0], "gt": [0, 0, 0], "na": 0}
    for ln in lines:
        mb = [0.0, 0.0, 0.0]
        for s, e, v in seg.get(ln, []):
            if 0 <= v <= 2:
                mb[v] += (e - s + 1) / 1e6
        called = sum(mb)
        gts = [0, 0, 0]
        na = 0
        for _k, (_x, gt) in geno.get(ln, {}).items():
            if gt is None:
                na += 1
            else:
                gts[gt] += 1
        n = sum(gts) + na
        excluded = qc.get(ln, True) is False
        if not excluded:
            for i in range(3):
                tot["mb"][i] += mb[i]
                tot["gt"][i] += gts[i]
            tot["na"] += na
        rows.append(_row(ln, excluded, mb, called, gts, na, n, expect))
    n = sum(tot["gt"]) + tot["na"]
    rows.append(_row("ALL", False, tot["mb"], sum(tot["mb"]), tot["gt"], tot["na"], n, expect))
    return rows


def _row(ln, excluded, mb, called, gts, na, n, expect):
    return {"line": ln, "excluded": excluded, "mb_x0": mb[0], "mb_x1": mb[1], "mb_x2": mb[2], "mb_called": called,
            "frac_x0": mb[0] / called if called else None, "frac_x1": mb[1] / called if called else None,
            "frac_x2": mb[2] / called if called else None, "exp_x0": expect[0], "exp_x1": expect[1], "exp_x2": expect[2],
            "sites": n, "sites_gt0": gts[0], "sites_gt1": gts[1], "sites_gt2": gts[2], "sites_na": na,
            "no_call_share": na / n if n else None}


def chi2_2df(counts, expect):
    n = sum(counts)
    if n == 0:
        return None, None
    stat = sum((c - n * p) ** 2 / (n * p) for c, p in zip(counts, expect))
    return stat, math.exp(-stat / 2.0)


def single_locus(alleles, geno, qc, expect):
    use = [ln for ln in geno if qc.get(ln, True) is not False]
    rows = []
    for r in alleles:
        if r["call_step"] == "multiallelic":
            continue
        xs = [0, 0, 0]
        g_sum = g_n = 0
        for ln in use:
            x, gt = geno[ln].get(r["key"], (None, None))
            if x is not None:
                xs[x] += 1
            if gt is not None:
                g_sum += gt
                g_n += 1
        n = sum(xs)
        stat, p = chi2_2df(xs, expect)
        rows.append({"chrom": r["key"][0], "pos": r["key"][1], "ref": r["key"][2], "alt": r["key"][3], "D": r["D"],
                     "call_step": r["call_step"], "n_lines": n, "n_x0": xs[0], "n_x1": xs[1], "n_x2": xs[2],
                     "donor_freq": (xs[1] + 2 * xs[2]) / (2 * n) if n else None,
                     "allele_freq_gt": g_sum / (2 * g_n) if g_n else None, "exp_freq": expect[1] / 2 + expect[2],
                     "het_freq": xs[1] / n if n else None, "exp_het": expect[1],
                     "x2_freq": xs[2] / n if n else None, "exp_x2": expect[2], "chi2": stat, "p_chi2": p})
    return rows


def breakpoints(segs):
    out = []
    for (s1, e1, v1), (s2, _e2, v2) in zip(segs, segs[1:]):
        if v1 != v2:
            out.append((e1 + s2) / 2.0)
    return out


def breakpoint_density(alleles, seg, qc, window):
    markers = sorted(r["key"][1] for r in alleles if r["call_step"] == "own")
    gaps = [(r["key"][1], r["call_step"] == "step2_alt") for r in alleles
            if r["call_step"] in ("step1_ref", "step1_alt", "step2_alt", "missing")]
    rows = []
    tot = [0, 0, 0, 0, 0]
    for ln in sorted(seg):
        if qc.get(ln, True) is False:
            continue
        bidx = sorted(bisect.bisect_left(markers, b) for b in breakpoints(seg[ln]))
        near = [0, 0]
        far = [0, 0]
        for pos, s2 in gaps:
            i = bisect.bisect_left(markers, pos)
            j = bisect.bisect_left(bidx, i)
            close = any(abs(bidx[k] - i) <= window for k in (j - 1, j) if 0 <= k < len(bidx))
            tgt = near if close else far
            tgt[0] += 1
            tgt[1] += s2
        rows.append(_brow(ln, len(bidx), near, far))
        tot[0] += len(bidx)
        tot[1] += near[0]
        tot[2] += near[1]
        tot[3] += far[0]
        tot[4] += far[1]
    rows.append(_brow("ALL", tot[0], [tot[1], tot[2]], [tot[3], tot[4]]))
    return rows, len(markers)


def _brow(ln, nb, near, far):
    rn = near[1] / near[0] if near[0] else None
    rf = far[1] / far[0] if far[0] else None
    return {"line": ln, "n_breakpoints": nb, "gap_sites_near": near[0], "step2_near": near[1], "step2_share_near": rn,
            "gap_sites_far": far[0], "step2_far": far[1], "step2_share_far": rf,
            "near_far_ratio": rn / rf if (rn is not None and rf) else None}


def write(path, rows, cols):
    with open(path, "w") as o:
        o.write(TAB.join(cols) + NL)
        for r in rows:
            o.write(TAB.join(fmt(r[c]) for c in cols) + NL)


LINE_COLS = ["line", "excluded", "mb_x0", "mb_x1", "mb_x2", "mb_called", "frac_x0", "frac_x1", "frac_x2", "exp_x0", "exp_x1",
             "exp_x2", "sites", "sites_gt0", "sites_gt1", "sites_gt2", "sites_na", "no_call_share"]
LOCUS_COLS = ["chrom", "pos", "ref", "alt", "D", "call_step", "n_lines", "n_x0", "n_x1", "n_x2", "donor_freq", "allele_freq_gt",
              "exp_freq", "het_freq", "exp_het", "x2_freq", "exp_x2", "chi2", "p_chi2"]
BP_COLS = ["line", "n_breakpoints", "gap_sites_near", "step2_near", "step2_share_near", "gap_sites_far", "step2_far",
           "step2_share_far", "near_far_ratio"]


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    genotypes = "${genotypes}"
    segments = opt_path("${segments}")
    alleles_path = "${donor_alleles}"
    line_qc = opt_path("${line_qc}")
    a = parse_args(shlex.split('''${task.ext.args ?: ''}'''))

    expect = EXPECT[a.expectation]
    seg = read_segments(segments)
    qc = read_line_qc(line_qc)
    alleles = read_alleles(alleles_path)
    geno = read_genotypes(genotypes)
    write(f"{prefix}.genotype_summary.tsv", line_summary(seg, geno, qc, expect), LINE_COLS)
    write(f"{prefix}.single_locus.tsv", single_locus(alleles, geno, qc, expect), LOCUS_COLS)
    bp, n_markers = breakpoint_density(alleles, seg, qc, a.breakpoint_window)
    write(f"{prefix}.breakpoint_density.tsv", bp, BP_COLS)
    log(f"{prefix}: {len(geno)} lines in the raster, {len(seg)} with segments, {len(alleles)} union rows, "
        f"{n_markers} own markers; expectation {a.expectation}, breakpoint window {a.breakpoint_window} markers")
    with open(f"{prefix}.genotype_summary.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
