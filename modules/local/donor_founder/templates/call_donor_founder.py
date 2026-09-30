#!/usr/bin/env python3
"""Final donor allele at every union site, one donor x region (DONOR_FOUNDER, stage 6; PLAN §3 row 6, design §2.5).

Nextflow module template (modules/local/donor_founder/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_call_donor_founder.py). Standard library only.

Per union allele (in union order), from step 1 (GAP_FILLING_BC1, the donor's rows) and step 2 (GAP_FILLING_LINES):
  multiallelic position           D = NA,  call_step multiallelic
  own tier-A site                 D = ALT, call_step own          (p_alt 1: ALT by discovery)
  step 1 REF                      D = REF, call_step step1_ref
  step 1 ALT                      D = ALT, call_step step1_alt
  step 1 missing, step 2 ALT      D = ALT, call_step step2_alt
  otherwise                       D = NA,  call_step missing
logodds = the evidence behind the call: step 2's combined log-odds where step 2 scored the site, else step 1's
(LLR + logit pi); '.' for own and multiallelic sites. p_alt = sigmoid(logodds) (1 for own), the E[D] that RASTERIZE turns
into dosage_expected (review #9).
Outputs
  <prefix>.tsv.gz        chrom pos ref alt D call_step logodds p_alt
  <prefix>.summary.tsv   one row: counts per call_step, and the step-1 and step-2 shares of the gaps reported separately
                         (review #2), missing share of the union
  <prefix>.donor_founder.versions.yml
"""
import argparse
import csv
import gzip
import io
import math
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)
NA = "NA"
DOT = "."
STEPS = ["own", "step1_ref", "step1_alt", "step2_alt", "missing", "multiallelic"]


def log(msg):
    sys.stderr.write("[donor_founder] " + msg + NL)


def gz_write(path):
    """Text writer of a gzip file with mtime 0, so equal content gives equal bytes (snapshots, reruns)."""
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), encoding="utf-8")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def num(s):
    return None if s in (NA, DOT, "") else float(s)


def sigmoid(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)


def fmt(x):
    if x is None:
        return DOT
    if isinstance(x, float):
        return NA if x != x else repr(x)
    return str(x)


def read_union(path):
    rows = []
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            rows.append(((r["chrom"], int(r["pos"]), r["ref"], r["alt"]), r["multiallelic"] == "1"))
    return rows


def read_step1(path, donor):
    t = {}
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            if r["donor"] == donor:
                t[(r["chrom"], int(r["pos"]), r["ref"], r["alt"])] = (r["src"], r["state"], num(r["logodds"]))
    return t


def read_step2(path):
    t = {}
    if not path:
        return t
    with open_text(path) as fh:
        for r in csv.DictReader(fh, delimiter=TAB):
            t[(r["chrom"], int(r["pos"]), r["ref"], r["alt"])] = (r["call"], num(r["logodds_combined"]))
    return t


def call_site(key, multi, s1, s2):
    """(D, call_step, logodds, p_alt) of one union allele."""
    if multi:
        return NA, "multiallelic", None, None
    if key not in s1:
        raise SystemExit(f"DONOR_FOUNDER: union allele {key} has no step-1 row for the donor")
    src, state, lo1 = s1[key]
    if src == "own":
        return "ALT", "own", None, 1.0
    if state == "REF":
        return "REF", "step1_ref", lo1, sigmoid(lo1)
    if state == "ALT":
        return "ALT", "step1_alt", lo1, sigmoid(lo1)
    call2, lo2 = s2.get(key, (None, None))
    lo = lo2 if lo2 is not None else lo1
    p = sigmoid(lo) if lo is not None else None
    if call2 == "ALT":
        return "ALT", "step2_alt", lo, p
    return NA, "missing", lo, p


def found(union, s1, s2):
    rows, cnt = [], {k: 0 for k in STEPS}
    for key, multi in union:
        d, step, lo, p = call_site(key, multi, s1, s2)
        cnt[step] += 1
        rows.append((key, d, step, lo, p))
    stale = [k for k in s2 if k in s1 and s1[k][0] == "gap" and s1[k][1] in ("ALT", "REF")]
    if stale:
        raise SystemExit(f"DONOR_FOUNDER: step 2 scored {len(stale)} sites step 1 already called (e.g. {stale[0]}): "
                         "the step-1 and step-2 tables are from different runs")
    return rows, cnt


def summary(donor, cnt):
    ok = sum(cnt[k] for k in STEPS if k != "multiallelic")
    gaps = ok - cnt["own"]
    s = {"donor": donor, "union_alleles": ok + cnt["multiallelic"], "biallelic": ok, "gaps": gaps}
    s.update(cnt)
    s["step1_share_of_gaps"] = (cnt["step1_ref"] + cnt["step1_alt"]) / gaps if gaps else None
    s["step2_share_of_gaps"] = cnt["step2_alt"] / gaps if gaps else None
    s["missing_share_of_gaps"] = cnt["missing"] / gaps if gaps else None
    s["missing_share_of_union"] = cnt["missing"] / ok if ok else None
    return s


SUMMARY_COLS = ["donor", "union_alleles", "biallelic", "gaps"] + STEPS + [
    "step1_share_of_gaps", "step2_share_of_gaps", "missing_share_of_gaps", "missing_share_of_union"]


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    donor = "${donor}"
    step1 = "${gap_bc1}"
    step2 = "${gap_lines}".strip()
    union = "${union}"
    argparse.ArgumentParser(prog="call_donor_founder.py").parse_args(shlex.split('''${task.ext.args ?: ''}'''))
    step2 = "" if step2 == "[]" else step2

    rows, cnt = found(read_union(union), read_step1(step1, donor), read_step2(step2))
    with gz_write(f"{prefix}.tsv.gz") as o:
        o.write(TAB.join(["chrom", "pos", "ref", "alt", "D", "call_step", "logodds", "p_alt"]) + NL)
        for key, d, step, lo, p in rows:
            o.write(TAB.join([key[0], str(key[1]), key[2], key[3], d, step, fmt(lo), fmt(p)]) + NL)
    s = summary(donor, cnt)
    with open(f"{prefix}.summary.tsv", "w") as o:
        o.write(TAB.join(SUMMARY_COLS) + NL)
        o.write(TAB.join(fmt(s[c]) for c in SUMMARY_COLS) + NL)
    log(f"{donor}: union {s['union_alleles']} (multiallelic {cnt['multiallelic']}) | own {cnt['own']} | gaps {s['gaps']}: "
        f"step 1 REF {cnt['step1_ref']}, ALT {cnt['step1_alt']} | step 2 ALT {cnt['step2_alt']} | missing {cnt['missing']}")
    if s["gaps"] == 0:
        log(f"WARN {prefix}: donor {donor} has 0 gap sites: every donor allele is its own tier A")
    with open(f"{prefix}.donor_founder.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
