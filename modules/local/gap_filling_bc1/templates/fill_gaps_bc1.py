#!/usr/bin/env python3
"""Gap filling step 1 (BC1) for every run donor of a set, one region (GAP_FILLING_BC1, stage 6; PLAN "Stage 6 — two-step gap
filling" step 1; math supplement Eq. S4.1 and S5.3; design §2.4-2.5). Rewrite of the maths of zealbc1 PHG/bin/dhd_bayes.py.

Nextflow module template (modules/local/gap_filling_bc1/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_fill_gaps_bc1.py). Standard library only.

Per run donor d and non-multiallelic union allele s:
  own  (d carries s in tier A)  -> ALT, never re-called.
  gap                            -> from d's joint recount at the union sites (JOINT_POOLED_LIKELIHOOD table):
     REF  if LLR <= --ref-llr (-4) and pooled depth n >= --ref-min-depth (12)   (REF from the donor's own reads only)
     ALT  if not flagged (--block-flags hidepth,af_gt_half) and
          logodds = LLR + logit(pi) >= logit(--gap-alt-posterior)   (compared on the log-odds scale at full precision,
          never on a rounded posterior; review_check "what the review missed")
     NA   otherwise (reason: absent = no BC1 read, blocked_flag, below_cutoff)
  prior pi (--gap-prior-source):
     other_donors  pi = (w mu_d + k) / (w + m)  (Eq. S5.3), over the prior donors: the other run donors plus the reference
                   donors of the union (--gap-prior-scope all | same_taxon, taxa from the donor_taxa input).
                   k = prior donors carrying s in tier A; m = k + prior donors with a REF call at s (run donor: the REF rule
                   above on its joint row; reference donor: tier `ref` in its own table, union column ref_donors).
                   With no prior donor at all this is exactly mu_only, and the summary says so (prior_source_used).
     fixed         pi = --gap-prior-fixed at every gap
     mu_only       pi = mu_d
  mu_d = (A + 0.5) / (A + R + 1) over d's gaps (A: joint tier A, R: REF calls), as dhd_bayes.py; pi clipped to [1e-6, 1-1e-6].
LLR at full precision: when the joint table has `logodds` (= LLR + logit(tier_prior), POOLED_LIKELIHOOD_TIERS) the LLR is
logodds - logit(--tier-prior) and must agree with the printed LLR column to rounding; else the LLR column is used as written.

Outputs
  <prefix>.tsv.gz       long, one row per run donor x union allele (multiallelic rows skipped):
                        chrom pos ref alt donor src tier n a n_pools_alt n0 a0 eps flags llr k m prior prior_source logodds
                        state reason     (state ALT | REF | NA; '.' = not applicable; floats at full precision)
  <prefix>.summary.tsv  per donor: taxon mu prior source (requested / used), prior donors, counts by state and reason
  <prefix>.gap_filling_bc1.versions.yml
A donor with 0 gap sites is logged as `WARN ... 0 gap sites: stage 6 has nothing to fill`.
"""
import argparse
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
    sys.stderr.write("[gap_filling_bc1] " + msg + NL)


def gz_write(path):
    """Text writer of a gzip file with mtime 0, so equal content gives equal bytes (snapshots, reruns)."""
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), encoding="utf-8")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def logit(p):
    return math.log(p / (1.0 - p))


def fmt(x):
    if x is None:
        return DOT
    if isinstance(x, float):
        return NA if x != x else repr(x)
    return str(x)


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="fill_gaps_bc1.py")
    ap.add_argument("--gap-alt-posterior", type=float, default=0.999)
    ap.add_argument("--gap-prior-w", type=float, default=2.0)
    ap.add_argument("--gap-prior-scope", choices=["all", "same_taxon"], default="all")
    ap.add_argument("--gap-prior-source", choices=["other_donors", "fixed", "mu_only"], default="other_donors")
    ap.add_argument("--gap-prior-fixed", type=float, default=0.5)
    ap.add_argument("--ref-llr", type=float, default=-4.0)
    ap.add_argument("--ref-min-depth", type=int, default=12)
    ap.add_argument("--tier-prior", type=float, default=0.5)
    ap.add_argument("--block-flags", default="hidepth,af_gt_half")
    a = ap.parse_args(argv)
    for name in ("gap_alt_posterior", "gap_prior_fixed", "tier_prior"):
        v = getattr(a, name)
        if not 0.0 < v < 1.0:
            ap.error(f"--{name.replace('_', '-')} must be in (0, 1), got {v}")
    if a.gap_prior_w <= 0:
        ap.error("--gap-prior-w must be > 0")
    a.block = {f for f in a.block_flags.split(",") if f}
    return a


def read_union(path):
    rows = []
    with open_text(path) as fh:
        header = fh.readline().rstrip(NL).split(TAB)
        c = {k: i for i, k in enumerate(header)}
        for need in ("chrom", "pos", "ref", "alt", "donors", "multiallelic"):
            if need not in c:
                raise SystemExit(f"GAP_FILLING_BC1: union has no column '{need}'")
        for line in fh:
            x = line.rstrip(NL).split(TAB)
            ds = [d for d in x[c["donors"]].split(",") if d]
            kinds = x[c["donor_kind"]].split(",") if "donor_kind" in c else ["run"] * len(ds)
            rd = x[c["ref_donors"]] if "ref_donors" in c else DOT
            rows.append({"key": (x[c["chrom"]], int(x[c["pos"]]), x[c["ref"]], x[c["alt"]]), "carriers": set(ds),
                         "reference_carriers": {d for d, k in zip(ds, kinds) if k == "reference"},
                         "ref_donors": set() if rd in (DOT, "") else set(rd.split(",")),
                         "multiallelic": x[c["multiallelic"]] == "1"})
    return rows


def read_joint(path, tier_prior):
    """{key: record} of one donor's joint step-4 table. LLR at full precision (see module doc)."""
    t, lo_prior = {}, logit(tier_prior)
    with open_text(path) as fh:
        header = fh.readline().rstrip(NL).split(TAB)
        c = {k: i for i, k in enumerate(header)}
        llr_col = "LLR" if "LLR" in c else "llr"
        for need in ("chrom", "pos", "ref", "alt", "n", "a", "tier", "flags", llr_col):
            if need not in c:
                raise SystemExit(f"GAP_FILLING_BC1: {os.path.basename(path)} has no column '{need}'")
        if "logodds" not in c:
            log(f"WARN {os.path.basename(path)}: no logodds column; LLR used at the printed precision")

        def opt(x, k, conv):
            return conv(x[c[k]]) if k in c and x[c[k]] not in (NA, DOT, "") else None

        for line in fh:
            x = line.rstrip(NL).split(TAB)
            llr = float(x[c[llr_col]])
            if "logodds" in c:
                full = float(x[c["logodds"]]) - lo_prior
                if abs(full - llr) > 0.006:
                    raise SystemExit(f"GAP_FILLING_BC1: {os.path.basename(path)} {x[c['pos']]}: logodds - logit(tier_prior "
                                     f"{tier_prior}) = {full} but LLR = {llr}; --tier-prior differs from the step-4 run")
                llr = full
            key = (x[c["chrom"]], int(x[c["pos"]]), x[c["ref"]], x[c["alt"]])
            t[key] = {"n": int(x[c["n"]]), "a": int(x[c["a"]]), "tier": x[c["tier"]], "flags": x[c["flags"]],
                      "llr": llr, "n_pools_alt": opt(x, "n_pools_alt", int), "n0": opt(x, "n0", int),
                      "a0": opt(x, "a0", int), "eps": opt(x, "eps", float)}
    return t


def assign_tables(files, donors):
    out = {}
    for f in files:
        base = os.path.basename(f)
        hits = [d for d in donors if base.startswith(d + ".")]
        if not hits:
            raise SystemExit(f"GAP_FILLING_BC1: joint table {base} matches no run donor of {donors}")
        d = max(hits, key=len)
        if d in out:
            raise SystemExit(f"GAP_FILLING_BC1: two joint tables for donor {d}")
        out[d] = f
    missing = [d for d in donors if d not in out]
    if missing:
        raise SystemExit(f"GAP_FILLING_BC1: no joint table for run donor(s) {missing}")
    return out


def is_ref_call(rec, a):
    return rec is not None and rec["llr"] <= a.ref_llr and rec["n"] >= a.ref_min_depth


def sharing_rate(d, union, joint, a):
    """mu_d = (A + 0.5) / (A + R + 1) over d's gaps; returns (mu, A, R)."""
    na = nr = 0
    for u in union:
        if u["multiallelic"] or d in u["carriers"]:
            continue
        rec = joint[d].get(u["key"])
        na += rec is not None and rec["tier"] == "A"
        nr += is_ref_call(rec, a)
    return (na + 0.5) / (na + nr + 1.0), na, nr


def prior_donors(d, run_donors, reference_donors, taxa, a):
    pool = [e for e in run_donors if e != d] + sorted(reference_donors)
    if a.gap_prior_scope == "all":
        return pool, []
    td = taxa.get(d)
    if td is None:
        log(f"WARN donor {d} has no taxon: same_taxon scope leaves it without prior donors")
        return [], pool
    keep = [e for e in pool if taxa.get(e) == td]
    return keep, [e for e in pool if e not in keep]


def prior_for(d, u, pdonors, run_donors, joint, mu, a):
    """(pi, k, m) at one gap."""
    if a.gap_prior_source == "fixed":
        return a.gap_prior_fixed, None, None
    if a.gap_prior_source == "mu_only":
        return min(max(mu, 1e-6), 1 - 1e-6), None, None
    k = sum(1 for e in pdonors if e in u["carriers"])
    m = k
    for e in pdonors:
        if e in u["carriers"]:
            continue
        if e in run_donors:
            m += is_ref_call(joint[e].get(u["key"]), a)
        else:
            m += e in u["ref_donors"]
    pi = (a.gap_prior_w * mu + k) / (a.gap_prior_w + m)
    return min(max(pi, 1e-6), 1 - 1e-6), k, m


def call_gap(rec, pi, a):
    """(state, reason, logodds) of one gap: REF rule, then absent, flags, the log-odds cut-off."""
    if rec is None:
        return NA, "absent", logit(pi)
    lo = rec["llr"] + logit(pi)
    if is_ref_call(rec, a):
        return "REF", "ref_rule", lo
    if set(rec["flags"].split(",")) & a.block:
        return NA, "blocked_flag", lo
    if lo >= logit(a.gap_alt_posterior):
        return "ALT", "posterior", lo
    return NA, "below_cutoff", lo


def fill(union, joint, run_donors, taxa, a):
    """Returns (rows, summaries)."""
    reference_donors = set()
    for u in union:
        reference_donors |= u["reference_carriers"] | u["ref_donors"]
    rows, summ = [], []
    for d in run_donors:
        mu, na, nr = sharing_rate(d, union, joint, a)
        pdon, dropped = prior_donors(d, run_donors, reference_donors, taxa, a)
        used = a.gap_prior_source
        if used == "other_donors" and not pdon:
            used = "mu_only (no prior donors)"
        s = {"donor": d, "taxon": taxa.get(d, NA), "mu": mu, "gap_tierA": na, "gap_ref": nr,
             "prior_source_requested": a.gap_prior_source, "prior_source_used": used, "n_prior_donors": len(pdon),
             "prior_donors": ",".join(pdon) or DOT, "prior_donors_other_taxon": ",".join(dropped) or DOT,
             "union_alleles": 0, "multiallelic_skipped": 0, "own": 0, "gaps": 0, "ALT": 0, "REF": 0, "NA": 0,
             "NA_absent": 0, "NA_blocked_flag": 0, "NA_below_cutoff": 0, "ref_rule_vs_tier_disagree": 0}
        for u in union:
            if u["multiallelic"]:
                s["multiallelic_skipped"] += 1
                continue
            s["union_alleles"] += 1
            rec = joint[d].get(u["key"])
            base = {"key": u["key"], "donor": d, "rec": rec}
            if d in u["carriers"]:
                s["own"] += 1
                rows.append(dict(base, src="own", k=None, m=None, prior=None, prior_source=DOT, logodds=None,
                                 state="ALT", reason="own"))
                continue
            s["gaps"] += 1
            pi, k, m = prior_for(d, u, pdon, run_donors, joint, mu, a)
            state, reason, lo = call_gap(rec, pi, a)
            s[state] += 1
            if state == NA:
                s["NA_" + reason] += 1
            if rec is not None and (rec["tier"] == "ref") != (state == "REF"):
                s["ref_rule_vs_tier_disagree"] += 1
            rows.append(dict(base, src="gap", k=k, m=m, prior=pi, prior_source=used, logodds=lo, state=state,
                             reason=reason))
        summ.append(s)
    return rows, summ


COLS = ["chrom", "pos", "ref", "alt", "donor", "src", "tier", "n", "a", "n_pools_alt", "n0", "a0", "eps", "flags", "llr",
        "k", "m", "prior", "prior_source", "logodds", "state", "reason"]
SUMMARY_COLS = ["donor", "taxon", "mu", "gap_tierA", "gap_ref", "prior_source_requested", "prior_source_used",
                "n_prior_donors", "prior_donors", "prior_donors_other_taxon", "union_alleles", "multiallelic_skipped",
                "own", "gaps", "ALT", "REF", "NA", "NA_absent", "NA_blocked_flag", "NA_below_cutoff",
                "ref_rule_vs_tier_disagree"]


def write_outputs(prefix, rows, summ):
    with gz_write(f"{prefix}.tsv.gz") as o:
        o.write(TAB.join(COLS) + NL)
        for r in rows:
            rec = r["rec"] or {}
            vals = [r["key"][0], r["key"][1], r["key"][2], r["key"][3], r["donor"], r["src"],
                    rec.get("tier", "absent"), rec.get("n", 0), rec.get("a", 0), rec.get("n_pools_alt"), rec.get("n0"),
                    rec.get("a0"), rec.get("eps"), rec.get("flags", DOT), rec.get("llr", float("nan")),
                    r["k"], r["m"], r["prior"], r["prior_source"], r["logodds"], r["state"], r["reason"]]
            o.write(TAB.join(fmt(v) for v in vals) + NL)
    with open(f"{prefix}.summary.tsv", "w") as o:
        o.write(TAB.join(SUMMARY_COLS) + NL)
        for s in summ:
            o.write(TAB.join(fmt(s[c]) for c in SUMMARY_COLS) + NL)


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    union_path = "${union}"
    run_donors = json.loads('''${groovy.json.JsonOutput.toJson(donors)}''')
    taxa = json.loads('''${groovy.json.JsonOutput.toJson(donor_taxa)}''')
    a = parse_args(shlex.split('''${task.ext.args ?: ''}'''))

    files = sorted(os.path.join("joint", f) for f in os.listdir("joint")) if os.path.isdir("joint") else []
    tables = assign_tables(files, run_donors)
    joint = {d: read_joint(tables[d], a.tier_prior) for d in run_donors}
    union = read_union(union_path)
    rows, summ = fill(union, joint, run_donors, taxa, a)
    write_outputs(prefix, rows, summ)
    for s in summ:
        log(f"{s['donor']}: mu {s['mu']:.3f} | prior {s['prior_source_used']} ({s['n_prior_donors']} prior donors) | "
            f"own {s['own']} | gaps {s['gaps']}: ALT {s['ALT']} / REF {s['REF']} / missing {s['NA']} "
            f"(absent {s['NA_absent']}, blocked_flag {s['NA_blocked_flag']}, below cut-off {s['NA_below_cutoff']})")
        if s["gaps"] == 0:
            log(f"WARN {prefix}: donor {s['donor']} has 0 gap sites: stage 6 has nothing to fill")
    with open(f"{prefix}.gap_filling_bc1.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
