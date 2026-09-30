#!/usr/bin/env python3
"""Gap filling step 2: per-line ALT rescue for one donor x region (GAP_FILLING_LINES, stage 6; PLAN "Stage 6 — two-step gap
filling" step 2, the additive rule decided 2026-09-28; design §2.5 with the review #1 fixes). The model of the tested
agent/20260928_001500_step2_combined.py (main checkout), rewritten in pure python; the rejected false-allele hypothesis is
not carried over.

Nextflow module template (modules/local/gap_filling_lines/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_fill_gaps_lines.py). Standard library only.

Candidates: the donor's gaps that step 1 left missing (gap_bc1 table: src gap, state NA). Per candidate s, in order:
  blocked_flag       step 1 blocked it for a step-4 flag (reason blocked_flag, or a --block-flags flag): never promoted (#1a)
  blocked_b73_lines  ALT reads in the x = 0 lines significantly above the zero-class error: one-sided binomial
                     P(X >= a_x0 | n_x0, eps0) < --b73-lines-alt-p, eps0 = (a0 + alpha) / (n0 + beta)          (#1b, flag)
                     and a_x0 >= --b73-lines-min-alt (default 1: with few x = 0 reads a single ALT read can reach
                     p < 0.01, e.g. 1 of 1 read at eps0 = 1/200 gives p = 0.005)
  no_test            no donor-segment line (x > 0) with reads information, or no depth scale from the x = 0 lines
  ALT | undecided    logodds = logit(pi) + LLR_BC1 + LLR_lines >= logit(--gap-alt-posterior) -> ALT; never REF
Lines: the donor's lines in the count table that have RTIGER segments and pass LINE_MARKER_QC; x = RTIGER dosage (0/1/2)
at s (a site outside every segment of the line, e.g. inside a breakpoint interval, has no x and the line is not used there).
Zero-class error (#1b): x = 0 lines are zero-class reads, so eps_s = (a0 + a_x0 + alpha) / (n0 + n_x0 + beta), with n0, a0
the zero-class reads behind the step-4 eps (JOINT_POOLED_LIKELIHOOD, carried in the gap_bc1 table), and eps_s is used in
both hypotheses: an ALT read in a B73-ancestry line raises eps_s instead of cancelling.
Line model (per line i: n_i reads, a_i ALT reads, h_i = x_i / 2, lambda_i = the line's mean depth at its x = 0 sites):
  depth    n_i ~ Pois(k_s lambda_i [(1 - h_i) + h_i c]),  k_s = max(sum_{x=0} n / sum_{x=0} lambda, --ks-floor)
  REF      a_i ~ Bin(n_i, eps_s)
  ALT      a_i ~ Bin(n_i, rho_i (1 - eps_s) + (1 - rho_i) eps_s),  rho_i = h_i c / [(1 - h_i) + h_i c]
  c (donor-copy mappability relative to B73) summed out on the grid of the taxon prior (<taxon>.prior.tsv: columns c and
  weight), or uniform on that grid (or on 0..--c-grid-max by --c-grid-step) with --mappability-prior-mode flat.
  LLR_lines = log sum_c p(c) P(n | c) P(a | n, ALT, c) - log sum_c p(c) P(n | c) P(a | n, REF)   (binomial coefficients cancel)
LLR_BC1 and pi come from step 1 (LLR 0 where the donor has no BC1 read). --lambda-sites all (default: every union site of
the donor) | candidates (the step-1 missing sites only, as the pilot script).

Outputs
  <prefix>.tsv.gz       chrom pos ref alt prior llr_bc1 llr_lines logodds_combined call eps_s eps0 n0 a0 n0_lines a0_lines
                        n_donor_lines a_donor_lines lines_x0 lines_donor ks p_b73_lines     (a0_lines = ALT reads in x = 0 lines)
  <prefix>.summary.tsv  one row: counts per call, lines used / excluded, the x = 0 ALT-read rate at the ALT calls and at the
                        undecided sites (review #3 bound), c prior used
  <prefix>.gap_filling_lines.versions.yml
"""
import argparse
import bisect
import csv
import gzip
import io
import json
import math
import os
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)
NA = "NA"
DOT = "."


def log(msg):
    sys.stderr.write("[gap_filling_lines] " + msg + NL)


def gz_write(path):
    """Text writer of a gzip file with mtime 0, so equal content gives equal bytes (snapshots, reruns)."""
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), encoding="utf-8")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def logit(p):
    return math.log(p / (1.0 - p))


def lse(v):
    m = max(v)
    if m == -math.inf:
        return m
    return m + math.log(sum(math.exp(x - m) for x in v))


def lbin(a, n, p):
    p = min(max(p, 1e-9), 1 - 1e-9)
    return a * math.log(p) + (n - a) * math.log(1 - p)


def binom_sf(a, n, p):
    """P(X >= a), X ~ Bin(n, p)."""
    if a <= 0:
        return 1.0
    if a > n:
        return 0.0
    p = min(max(p, 1e-12), 1 - 1e-12)
    lp, lq = math.log(p), math.log(1 - p)
    terms = [math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1) + k * lp + (n - k) * lq for k in range(a, n + 1)]
    return min(1.0, math.exp(lse(terms)))


def fmt(x):
    if x is None:
        return NA
    if isinstance(x, float):
        return NA if x != x else repr(x)
    return str(x)


def num(s, conv=float):
    return None if s in (NA, DOT, "") else conv(s)


def opt_path(s):
    """An optional path input given as [] renders as '' (or '[]')."""
    s = s.strip()
    return "" if s in ("", "[]") else s


def norm_chrom(c):
    c = str(c)
    return c[3:] if c.lower().startswith("chr") else c


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="fill_gaps_lines.py")
    ap.add_argument("--gap-alt-posterior", type=float, default=0.999)
    ap.add_argument("--eps-prior-alpha", type=float, default=1.0)
    ap.add_argument("--eps-prior-beta", type=float, default=200.0)
    ap.add_argument("--b73-lines-alt-p", type=float, default=0.01)
    ap.add_argument("--b73-lines-min-alt", type=int, default=1)
    ap.add_argument("--ks-floor", type=float, default=0.02)
    ap.add_argument("--mappability-prior-mode", choices=["taxon", "flat"], default="taxon")
    ap.add_argument("--c-grid-max", type=float, default=1.5)
    ap.add_argument("--c-grid-step", type=float, default=0.05)
    ap.add_argument("--lambda-sites", choices=["all", "candidates"], default="all")
    ap.add_argument("--block-flags", default="hidepth,af_gt_half")
    a = ap.parse_args(argv)
    if not 0.0 < a.gap_alt_posterior < 1.0:
        ap.error("--gap-alt-posterior must be in (0, 1)")
    if a.eps_prior_alpha <= 0 or a.eps_prior_beta <= a.eps_prior_alpha:
        ap.error("--eps-prior-alpha must be > 0 and --eps-prior-beta > alpha")
    a.block = {f for f in a.block_flags.split(",") if f}
    return a


# ------------------------------------------------------------------ inputs
def read_gap_bc1(path, donor):
    rows = []
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            if r["donor"] != donor:
                continue
            rows.append({"key": (r["chrom"], int(r["pos"]), r["ref"], r["alt"]), "src": r["src"], "state": r["state"],
                         "reason": r["reason"], "flags": r["flags"], "prior": num(r["prior"]), "llr": num(r["llr"]),
                         "n0": num(r["n0"], int), "a0": num(r["a0"], int)})
    return rows


def ad_name(field):
    """'[5]PN5_SID464:AD' or 'PN5_SID464:AD' -> 'PN5_SID464' (bcftools query -H)."""
    if field.startswith("#"):
        field = field[1:].strip()
    if field.startswith("[") and "]" in field:
        field = field.split("]", 1)[1]
    return field.rsplit(":", 1)[0] if field.endswith(":AD") else field


def read_ad(path):
    """ALLELE_COUNTS table (bcftools query -H -f chrom pos ref alt [AD]) -> (sample names, {(chrom, pos): (ref, alts, ADs)})."""
    names, t = [], {}
    with open_text(path) as fh:
        for line in fh:
            x = line.rstrip(NL).split(TAB)
            if line.startswith("#"):
                names = [ad_name(f) for f in x[4:]]
                continue
            if len(x[2]) != 1:
                continue
            ads = [[int(v) for v in f.split(",")] if f not in (DOT, "") else [] for f in x[4:]]
            t[(x[0], int(x[1]))] = (x[2], x[3].split(","), ads)
    return names, t


def site_counts(t, key, nlines):
    """(n, a) per line at one site: n = REF + ALT reads, a = ALT reads; an allele missing from the record counts 0."""
    rec = t.get((key[0], key[1]))
    if rec is None or rec[0] != key[2]:
        return [0] * nlines, [0] * nlines
    _ref, alts, ads = rec
    j = alts.index(key[3]) + 1 if key[3] in alts else None
    n, a = [], []
    for ad in ads:
        r = ad[0] if ad else 0
        k = ad[j] if (j is not None and len(ad) > j) else 0
        n.append(r + k)
        a.append(k)
    return n, a


def read_segments(path, chrom):
    """{line: ([starts], [(start, end, state)])} of the RTIGER segments on chrom (CSV or TSV: name chr start_bp end_bp state)."""
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
            if norm_chrom(r["chr"]) != norm_chrom(chrom):
                continue
            seg.setdefault(r["name"], []).append((int(float(r["start_bp"])), int(float(r["end_bp"])), int(float(r["state"]))))
    return {k: ([s[0] for s in sorted(v)], sorted(v)) for k, v in seg.items()}


def ancestry(seg, line, pos):
    """RTIGER dosage x of line at pos, -1 outside every segment."""
    if line not in seg:
        return -1
    starts, segs = seg[line]
    i = bisect.bisect_right(starts, pos) - 1
    if i < 0:
        return -1
    s, e, v = segs[i]
    return v if s <= pos <= e else -1


def read_line_qc(path):
    """{sample: line_pass} from LINE_MARKER_QC's line_qc.tsv: columns sample and line_pass (true|false), one row per contig."""
    out = {}
    if not path:
        return out
    with open_text(path) as fh:
        rd = csv.DictReader(fh, delimiter=TAB)
        cols = rd.fieldnames or []
        if "sample" not in cols or "line_pass" not in cols:
            raise SystemExit(f"GAP_FILLING_LINES: line_qc {path} needs the LINE_MARKER_QC columns sample and line_pass, has {cols}")
        for r in rd:
            v = r["line_pass"].strip().lower()
            if v not in ("true", "false"):
                raise SystemExit(f"GAP_FILLING_LINES: line_qc {path}: line_pass of {r['sample']} is {r['line_pass']!r}, not true/false")
            if out.setdefault(r["sample"], v == "true") != (v == "true"):
                raise SystemExit(f"GAP_FILLING_LINES: line_qc {path}: line_pass of {r['sample']} differs between its contig rows")
    return out


def read_c_prior(path, mode, grid_max, step):
    """(grid, log weights) of the mappability prior; flat = uniform on the file's grid, or on 0..grid_max by step."""
    grid, w = [], []
    if path:
        with open_text(path) as fh:
            rd = csv.DictReader(fh, delimiter=TAB)
            wc = next((c for c in ("weight", "p", "prob", "count") if c in (rd.fieldnames or [])), None)
            if "c" not in (rd.fieldnames or []) or wc is None:
                raise SystemExit(f"GAP_FILLING_LINES: prior {path} needs columns c and weight, has {rd.fieldnames}")
            for r in rd:
                grid.append(float(r["c"]))
                w.append(float(r[wc]))
    elif mode == "flat":
        nb = int(round(grid_max / step))
        grid = [round(i * step, 10) for i in range(nb + 1)]
        w = [1.0] * len(grid)
    else:
        raise SystemExit("GAP_FILLING_LINES: no mappability prior file and --mappability-prior-mode taxon")
    if mode == "flat":
        w = [1.0] * len(grid)
    if not grid or any(c < 0 for c in grid) or any(v < 0 for v in w) or sum(w) <= 0:
        raise SystemExit("GAP_FILLING_LINES: the mappability prior needs c >= 0 and non-negative weights with a positive sum")
    tot = sum(w)
    keep = [(c, math.log(v / tot)) for c, v in zip(grid, w) if v > 0]
    return [k[0] for k in keep], [k[1] for k in keep]


# ------------------------------------------------------------------ model
def line_lambdas(keys, t, idx, xs_of, lines):
    """lambda_i = mean REF+ALT depth of line i over the keys where its x = 0 (None if it has no x = 0 site)."""
    tot = {ln: 0 for ln in lines}
    cnt = {ln: 0 for ln in lines}
    for key in keys:
        n, _a = site_counts(t, key, len(idx))
        xs = xs_of(key)
        for ln in lines:
            if xs[ln] == 0:
                tot[ln] += n[idx[ln]]
                cnt[ln] += 1
    return {ln: (tot[ln] / cnt[ln] if cnt[ln] else None) for ln in lines}


def llr_lines(n, a, x, lam, eps, grid, logw, ks_floor):
    """LLR_lines and k_s at one site; n, a, x, lam are lists over the usable lines (x in 0..2, lam > 0). None = no test."""
    b73 = [i for i, v in enumerate(x) if v == 0]
    don = [i for i, v in enumerate(x) if v > 0]
    lam_b73 = sum(lam[i] for i in b73)
    if not don or lam_b73 <= 0:
        return None
    ks = max(sum(n[i] for i in b73) / lam_b73, ks_floor)
    h = [v / 2.0 for v in x]
    lp_depth, lp_alt = [], []
    for c, lw in zip(grid, logw):
        d = 0.0
        al = 0.0
        for i in range(len(x)):
            mu = max(ks * lam[i] * ((1 - h[i]) + h[i] * c), 1e-9)
            d += n[i] * math.log(mu) - mu
            den = (1 - h[i]) + h[i] * c
            rho = (h[i] * c) / den if den > 1e-12 else 0.0
            al += lbin(a[i], n[i], rho * (1 - eps) + (1 - rho) * eps)
        lp_depth.append(d + lw)
        lp_alt.append(d + lw + al)
    l_ref = lse(lp_depth) + sum(lbin(a[i], n[i], eps) for i in range(len(x)))
    l_alt = lse(lp_alt)
    return l_alt - l_ref, ks


def score_candidate(row, n, a, x, lam, grid, logw, a_):
    """One candidate: returns the output record (dict)."""
    alpha, beta = a_.eps_prior_alpha, a_.eps_prior_beta
    n0 = row["n0"] or 0
    a0 = row["a0"] or 0
    b73 = [i for i, v in enumerate(x) if v == 0]
    don = [i for i, v in enumerate(x) if v > 0]
    nx0 = sum(n[i] for i in b73)
    ax0 = sum(a[i] for i in b73)
    eps0 = (a0 + alpha) / (n0 + beta)
    eps_s = (a0 + ax0 + alpha) / (n0 + nx0 + beta)
    pi = row["prior"]
    llr1 = row["llr"] if row["llr"] is not None else 0.0
    rec = {"prior": pi, "llr_bc1": llr1, "llr_lines": None, "logodds_combined": None, "eps_s": eps_s, "eps0": eps0,
           "n0": n0, "a0": a0, "n0_lines": nx0, "a0_lines": ax0, "n_donor_lines": sum(n[i] for i in don),
           "a_donor_lines": sum(a[i] for i in don), "lines_x0": len(b73), "lines_donor": len(don), "ks": None,
           "p_b73_lines": None}
    flagged = row["reason"] == "blocked_flag" or bool(set((row["flags"] or DOT).split(",")) & a_.block)
    if flagged:
        rec["call"] = "blocked_flag"
        return rec
    if ax0 > 0 and ax0 >= a_.b73_lines_min_alt:
        p = binom_sf(ax0, nx0, eps0)
        rec["p_b73_lines"] = p
        if p < a_.b73_lines_alt_p:
            rec["call"] = "blocked_b73_lines"
            return rec
    t = llr_lines(n, a, x, lam, eps_s, grid, logw, a_.ks_floor)
    if t is None:
        rec["call"] = "no_test"
        return rec
    rec["llr_lines"], rec["ks"] = t
    lo = (logit(pi) if pi is not None else 0.0) + llr1 + rec["llr_lines"]
    rec["logodds_combined"] = lo
    rec["call"] = "ALT" if lo >= logit(a_.gap_alt_posterior) else "undecided"
    return rec


def run(rows, names, t, seg, qc, grid, logw, a_):
    """Returns (records [(key, rec)], summary dict)."""
    idx = {ln: i for i, ln in enumerate(names)}
    excluded = [ln for ln in names if qc.get(ln) is False]
    no_seg = [ln for ln in names if ln not in seg and qc.get(ln) is not False]
    usable = [ln for ln in names if ln in seg and qc.get(ln) is not False]
    def xs_of(key):
        return {ln: ancestry(seg, ln, key[1]) for ln in usable}

    cands = [r for r in rows if r["src"] == "gap" and r["state"] == NA]
    lam_keys = [r["key"] for r in rows] if a_.lambda_sites == "all" else [r["key"] for r in cands]
    lam = line_lambdas(lam_keys, t, idx, xs_of, usable)
    no_lam = [ln for ln in usable if not lam[ln]]
    use = [ln for ln in usable if lam[ln]]
    out = []
    for r in cands:
        n_all, a_all = site_counts(t, r["key"], len(names))
        xs = xs_of(r["key"])
        sel = [ln for ln in use if xs[ln] >= 0]
        rec = score_candidate(r, [n_all[idx[ln]] for ln in sel], [a_all[idx[ln]] for ln in sel],
                              [xs[ln] for ln in sel], [lam[ln] for ln in sel], grid, logw, a_)
        out.append((r["key"], rec))
    calls = [rec["call"] for _k, rec in out]

    def x0_rate(call):
        nn = sum(rec["n0_lines"] for _k, rec in out if rec["call"] == call)
        aa = sum(rec["a0_lines"] for _k, rec in out if rec["call"] == call)
        return aa / nn if nn else None

    summ = {"candidates": len(cands), "ALT": calls.count("ALT"), "undecided": calls.count("undecided"),
            "blocked_flag": calls.count("blocked_flag"), "blocked_b73_lines": calls.count("blocked_b73_lines"),
            "no_test": calls.count("no_test"), "lines_in_counts": len(names), "lines_used": len(use),
            "lines_excluded_qc": len(excluded), "lines_without_segments": len(no_seg), "lines_without_x0_depth": len(no_lam),
            "alt_calls_with_x0_alt_reads": sum(1 for _k, rec in out if rec["call"] == "ALT" and rec["a0_lines"] > 0),
            "x0_alt_rate_at_ALT": x0_rate("ALT"), "x0_alt_rate_at_undecided": x0_rate("undecided"),
            "median_lambda": (sorted(lam[ln] for ln in use)[len(use) // 2] if use else None)}
    return out, summ


OUT_COLS = ["prior", "llr_bc1", "llr_lines", "logodds_combined", "call", "eps_s", "eps0", "n0", "a0", "n0_lines", "a0_lines",
            "n_donor_lines", "a_donor_lines", "lines_x0", "lines_donor", "ks", "p_b73_lines"]
SUMMARY_COLS = ["donor", "candidates", "ALT", "undecided", "blocked_flag", "blocked_b73_lines", "no_test", "lines_in_counts",
                "lines_used", "lines_excluded_qc", "lines_without_segments", "lines_without_x0_depth",
                "alt_calls_with_x0_alt_reads", "x0_alt_rate_at_ALT", "x0_alt_rate_at_undecided", "median_lambda", "c_prior",
                "c_grid_bins", "eps_prior_alpha", "eps_prior_beta", "gap_alt_posterior", "lambda_sites"]


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    donor = "${donor}"
    gap_bc1 = "${gap_bc1}"
    lines_ad = "${lines_counts}"
    segments = "${segments}"
    line_qc = opt_path("${line_qc}")
    c_prior = opt_path("${c_prior}")
    a_ = parse_args(shlex.split('''${task.ext.args ?: ''}'''))

    rows = [r for r in read_gap_bc1(gap_bc1, donor)]
    if not rows:
        log(f"WARN {prefix}: donor {donor} has no rows in {gap_bc1}")
    chrom = rows[0]["key"][0] if rows else ""
    names, t = read_ad(lines_ad)
    seg = read_segments(segments, chrom)
    qc = read_line_qc(line_qc)
    grid, logw = read_c_prior(c_prior, a_.mappability_prior_mode, a_.c_grid_max, a_.c_grid_step)
    out, summ = run(rows, names, t, seg, qc, grid, logw, a_)
    summ.update({"donor": donor, "c_prior": (os.path.basename(c_prior) if c_prior else "none") + ":" + a_.mappability_prior_mode,
                 "c_grid_bins": len(grid), "eps_prior_alpha": a_.eps_prior_alpha, "eps_prior_beta": a_.eps_prior_beta,
                 "gap_alt_posterior": a_.gap_alt_posterior, "lambda_sites": a_.lambda_sites})
    with gz_write(f"{prefix}.tsv.gz") as o:
        o.write(TAB.join(["chrom", "pos", "ref", "alt"] + OUT_COLS) + NL)
        for key, rec in out:
            o.write(TAB.join([key[0], str(key[1]), key[2], key[3]] + [fmt(rec[c]) for c in OUT_COLS]) + NL)
    with open(f"{prefix}.summary.tsv", "w") as o:
        o.write(TAB.join(SUMMARY_COLS) + NL)
        o.write(TAB.join(fmt(summ[c]) for c in SUMMARY_COLS) + NL)
    log(f"{donor}: {summ['candidates']} sites missing after step 1 | ALT {summ['ALT']} | undecided {summ['undecided']} | "
        f"blocked_flag {summ['blocked_flag']} | blocked_b73_lines {summ['blocked_b73_lines']} | no_test {summ['no_test']} | "
        f"lines used {summ['lines_used']} of {summ['lines_in_counts']} (QC-excluded {summ['lines_excluded_qc']}, "
        f"no segments {summ['lines_without_segments']})")
    if summ["candidates"] == 0:
        log(f"WARN {prefix}: donor {donor} has 0 gap sites missing after step 1: step 2 has nothing to fill")
    with open(f"{prefix}.gap_filling_lines.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
