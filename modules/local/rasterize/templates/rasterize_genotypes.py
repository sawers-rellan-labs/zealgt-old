#!/usr/bin/env python3
"""Genotypes of a donor's lines at the union sites, one donor x region (RASTERIZE, stage 7; PLAN §3 row 7; math supplement
Eq. S5.1 "Genotype as ancestry times donor allele"; design §2.6).

Nextflow module template (modules/local/rasterize/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_rasterize_genotypes.py). Standard library only.

Per line and non-multiallelic union allele, with x = the RTIGER dosage (copies of the donor segment, 0/1/2) at the site and
D = the donor allele (DONOR_FOUNDER):
  x unknown (outside every segment of the line, or the line excluded by LINE_MARKER_QC)   -> gt NA
  D = ALT -> gt = x;   D = REF -> gt = 0;   D = NA and x > 0 -> gt NA;   D = NA and x = 0 -> gt 0
  dosage_expected = x * p_alt (p_alt = E[D], DONOR_FOUNDER; 1 at own sites), NA where x is unknown: a GWAS need not
  mean-impute NA toward B73 (review #9).
Lines = those with segments plus those in line_qc (an excluded line is NA everywhere, PLAN §4 #13).
Outputs
  <prefix>.tsv.gz         long: line chrom pos ref alt x D gt dosage_expected
  <prefix>.matrix.tsv.gz  wide: one row per site (chrom pos ref alt), one gt column per line
  <prefix>.rasterize.versions.yml
"""
import argparse
import bisect
import csv
import gzip
import io
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)
NA = "NA"
DOT = "."
TRUE = {"true", "t", "pass", "passed", "1", "yes", "y", "ok"}


def log(msg):
    sys.stderr.write("[rasterize] " + msg + NL)


def gz_write(path):
    """Text writer of a gzip file with mtime 0, so equal content gives equal bytes (snapshots, reruns)."""
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), encoding="utf-8")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def opt_path(s):
    s = s.strip()
    return "" if s in ("", "[]") else s


def norm_chrom(c):
    c = str(c)
    return c[3:] if c.lower().startswith("chr") else c


def read_alleles(path):
    rows, multi = [], 0
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            if r["call_step"] == "multiallelic":
                multi += 1
                continue
            p = r.get("p_alt", DOT)
            rows.append({"chrom": r["chrom"], "pos": int(r["pos"]), "ref": r["ref"], "alt": r["alt"], "D": r["D"],
                         "p_alt": None if p in (NA, DOT, "") else float(p)})
    return rows, multi


def read_segments(path):
    """{line: {norm chrom: ([starts], [(start, end, state)])}} (CSV or TSV: name chr start_bp end_bp state)."""
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
            seg.setdefault(r["name"], {}).setdefault(norm_chrom(r["chr"]), []).append(
                (int(float(r["start_bp"])), int(float(r["end_bp"])), int(float(r["state"]))))
    return {ln: {c: ([s[0] for s in sorted(v)], sorted(v)) for c, v in by.items()} for ln, by in seg.items()}


def read_line_qc(path):
    out = {}
    if not path:
        return out
    with open_text(path) as fh:
        rd = csv.DictReader(fh, delimiter=TAB)
        cols = rd.fieldnames or []
        idc = next((c for c in ("sample", "line", "name", "sample_id") if c in cols), None)
        pc = next((c for c in ("pass", "status", "include", "passed") if c in cols), None)
        if idc is None or (pc is None and "excluded" not in cols):
            raise SystemExit(f"RASTERIZE: line_qc {path} needs a sample and a pass/excluded column, has {cols}")
        for r in rd:
            out[r[idc]] = (r[pc].strip().lower() in TRUE) if pc else (r["excluded"].strip().lower() not in TRUE)
    return out


def ancestry(seg_line, chrom, pos):
    by = seg_line.get(norm_chrom(chrom)) if seg_line else None
    if not by:
        return None
    starts, segs = by
    i = bisect.bisect_right(starts, pos) - 1
    if i < 0:
        return None
    s, e, v = segs[i]
    return v if s <= pos <= e else None


def genotype(x, d):
    """Eq. S5.1: gt of dosage x (None = unknown) and donor allele d; None = NA."""
    if x is None:
        return None
    if d == "ALT":
        return x
    if d == "REF":
        return 0
    return 0 if x == 0 else None


def raster(alleles, seg, qc):
    lines = sorted(set(seg) | set(qc))
    out = {}
    for ln in lines:
        ok = qc.get(ln, True)
        col = []
        for r in alleles:
            x = ancestry(seg.get(ln), r["chrom"], r["pos"]) if ok else None
            gt = genotype(x, r["D"])
            dose = None
            if x is not None:
                dose = 0.0 if x == 0 else (x * r["p_alt"] if r["p_alt"] is not None else None)
            col.append((x, gt, dose))
        out[ln] = col
    return lines, out


def f(v):
    if v is None:
        return NA
    return repr(v) if isinstance(v, float) else str(v)


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    alleles_path = "${donor_alleles}"
    segments = opt_path("${segments}")
    line_qc = opt_path("${line_qc}")
    argparse.ArgumentParser(prog="rasterize_genotypes.py").parse_args(shlex.split('''${task.ext.args ?: ''}'''))

    alleles, multi = read_alleles(alleles_path)
    seg = read_segments(segments)
    qc = read_line_qc(line_qc)
    lines, out = raster(alleles, seg, qc)
    with gz_write(f"{prefix}.tsv.gz") as o:
        o.write(TAB.join(["line", "chrom", "pos", "ref", "alt", "x", "D", "gt", "dosage_expected"]) + NL)
        for ln in lines:
            for r, (x, gt, dose) in zip(alleles, out[ln]):
                o.write(TAB.join([ln, r["chrom"], str(r["pos"]), r["ref"], r["alt"], f(x), r["D"], f(gt), f(dose)]) + NL)
    with gz_write(f"{prefix}.matrix.tsv.gz") as o:
        o.write(TAB.join(["chrom", "pos", "ref", "alt"] + lines) + NL)
        for i, r in enumerate(alleles):
            o.write(TAB.join([r["chrom"], str(r["pos"]), r["ref"], r["alt"]] + [f(out[ln][i][1]) for ln in lines]) + NL)
    n_na = sum(1 for ln in lines for v in out[ln] if v[1] is None)
    excl = [ln for ln in lines if not qc.get(ln, True)]
    log(f"{prefix}: {len(lines)} lines ({len(excl)} excluded by line QC) x {len(alleles)} sites "
        f"({multi} multiallelic union rows dropped); NA cells {n_na} of {len(lines) * len(alleles)}")
    with open(f"{prefix}.rasterize.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
