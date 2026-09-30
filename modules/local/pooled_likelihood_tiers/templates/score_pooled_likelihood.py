#!/usr/bin/env python3
"""Pooled likelihood ratio and tiers per donor and site (POOLED_LIKELIHOOD_TIERS / JOINT_POOLED_LIKELIHOOD, genotype design
section 2.2; math supplement "Per-donor variant discovery"; the step-4 maths of zealbc1 pilot_step4_postfilter_llr.py, rewritten).

Nextflow module template (modules/local/pooled_likelihood_tiers/main.nf): the Groovy placeholders are filled in by Nextflow,
so the task hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (the
template engine would read them); tab and newline are chr(9) / chr(10).

Model. Pool i (a BC1 sample, 6 plants = 12 haplotypes) has n_i reads at a site, a_i of them ALT. With site error rate eps,
  H1: L1_i = sum_{j=0..P} C(P,j) 2^-P Bin(a_i; n_i, p_j),  p_j = (j/2P)(1-eps) + (1 - j/2P) eps     (j carrier plants)
  H0: L0_i = Bin(a_i; n_i, eps)
  LLR_d = sum over the donor's pools of log L1_i - log L0_i;  logodds = LLR_d + logit(prior);  posterior = sigmoid(logodds)
j = 0 is part of H1, so a pool without ALT reads is no evidence against the allele (per-pool floor log 2^-P).
Site error rate: the zero class = every pool of a donor whose LLR at --eps0 is < --zero-class-llr (the B73 controls and,
in a joint run, the non-carrier donors; the witness only with --witness-zero-class). With n0 >= --zero-class-min-reads
reads, a0 of them ALT: eps = max((a0 + 0.5) / (n0 + 1), --eps-floor); else eps = --eps0 and flag no_zero_class.
n0 and a0 are written per site (design section 2.2: stage 6 builds its own zero-class eps from them, review #1b), with
self_in_zero = 1 when the scored donor's own pools are part of that zero class.
Flags (per donor and site): hidepth (all pools' reads at the site > --hidepth-factor x the median over records),
af_gt_half (n >= --af-gt-half-min-depth, a/n > 1/2 and P(X >= a | n, 1/2) < --af-gt-half-p), single_sample (one pool),
inconsistent (several pools; one with >= --inconsistent-min-alt ALT reads and another with >= --inconsistent-min-depth reads
and none ALT), no_zero_class.
Tiers (on LLR, as the tier_llr_* params):
  A    LLR >= --llr-a, ALT reads in >= --a-min-pools-alt pools (or, when --a-single-pool-min-alt > 0 and the donor has
       <= --a-single-pool-max-pools pools, >= 1 pool with ALT and >= that many ALT reads; review #10), no hidepth /
       af_gt_half / inconsistent
  B    LLR >= --llr-b, no hidepth / af_gt_half
  C    LLR >= --llr-c
  ref  LLR <= --llr-ref, n >= --ref-min-depth and >= --ref-min-pools pools with reads
  -    otherwise
Only biallelic SNP records are scored; others are counted in run_info.
Input formats (--input-format; auto = crisp_vcf when the calls file is a VCF):
  crisp_vcf  calls = one CRISP VCF (per-pool ADf, ADr, ADb, 'ref,alt' each; n = ref + alt summed over the three);
             extra = count tables (the B73 controls) looked up at each record's alleles
  counts     calls + extra = ALLELE_COUNTS tables (bcftools query -H header CHROM POS REF ALT <sample>:AD..., AD in REF,ALT
             order; a plain chrom pos ref alt <sample> header is read too); sites =
             the site list (chrom pos ref alt; header lines skipped); a record is a site with >= 1 read in any pool
In a count table, n = AD(REF) + AD(site ALT) (other alleles ignored), a = AD(site ALT), 0 when mpileup did not see the
allele; a site absent from a table, or with another REF, counts (0, 0) for that table's samples.
Sample map (val input): [sample, donor, taxon, role], role bc1_sample | witness | b73_control. Every pool must be in it.
Only bc1_sample donors get a sites table; witness and b73_control pools act as their own donors (zealbc1 map.tsv).
Writes, <label> = the region with ':' replaced by '_':
  <donor>.<label>.sites.tsv.gz  per called donor; columns chrom pos ref alt n a n_pools n_pools_alt eps n0 a0 self_in_zero
                                LLR logodds posterior tier flags [in_<annotation> ...] pool_counts (sample:a/n;...);
                                LLR, logodds, eps at full precision (review_check:37-38: a rounded posterior misclassifies).
                                Rows only where the donor has reads, unless --keep-zero-depth.
  <prefix>.summary.tsv          per called donor: tier counts, tier x annotation overlaps
  <prefix>.pool_qc.tsv          per pool: sites with reads, ALT / REF reads, ALT fraction, sites with ALT fraction > 1/2
  <prefix>.run_info.txt         inputs, record counts, median depth, every option
  <prefix>.pooled_likelihood_tiers.versions.yml
Standard library only.
"""
import argparse
import gzip
import json
import math
import platform
import shlex
import statistics
import sys
from collections import Counter

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
CALLS = "${calls}".split()
EXTRA = "${extra_counts}".split()
SITES = "${sites}".split()
REGION = "${region}"
SAMPLE_MAP = [list(r) for r in json.loads('''${groovy.json.JsonOutput.toJson(sample_map)}''')]
ANNOT_NAMES = json.loads('''${groovy.json.JsonOutput.toJson(annotation_names ?: [])}''')
ANNOT_FILES = "${annotations}".split()
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')

ROLES = ("bc1_sample", "witness", "b73_control")


def parse_args():
    ap = argparse.ArgumentParser(prog="score_pooled_likelihood.py")
    ap.add_argument("--input-format", choices=("auto", "crisp_vcf", "counts"), default="auto")
    ap.add_argument("--eps0", type=float, default=0.005)
    ap.add_argument("--prior", type=float, default=0.5)
    ap.add_argument("--plants", type=int, default=6)
    ap.add_argument("--zero-class-llr", type=float, default=-3.0)
    ap.add_argument("--zero-class-min-reads", type=int, default=20)
    ap.add_argument("--eps-floor", type=float, default=0.001)
    ap.add_argument("--llr-a", type=float, default=6.9)
    ap.add_argument("--llr-b", type=float, default=4.6)
    ap.add_argument("--llr-c", type=float, default=2.2)
    ap.add_argument("--llr-ref", type=float, default=-4.0)
    ap.add_argument("--ref-min-depth", type=int, default=12)
    ap.add_argument("--ref-min-pools", type=int, default=1)
    ap.add_argument("--a-min-pools-alt", type=int, default=2)
    ap.add_argument("--a-single-pool-min-alt", type=int, default=0)
    ap.add_argument("--a-single-pool-max-pools", type=int, default=2)
    ap.add_argument("--hidepth-factor", type=float, default=2.0)
    ap.add_argument("--af-gt-half-p", type=float, default=0.01)
    ap.add_argument("--af-gt-half-min-depth", type=int, default=4)
    ap.add_argument("--inconsistent-min-alt", type=int, default=3)
    ap.add_argument("--inconsistent-min-depth", type=int, default=10)
    ap.add_argument("--witness-zero-class", dest="witness_zero_class", action="store_true", default=True)
    ap.add_argument("--no-witness-zero-class", dest="witness_zero_class", action="store_false")
    ap.add_argument("--keep-zero-depth", action="store_true")
    a = ap.parse_args(EXT_ARGS)
    if not 0 < a.prior < 1 or not 0 < a.eps0 < 0.5 or not 0 < a.eps_floor < 0.5 or a.plants < 1:
        sys.exit("POOLED_LIKELIHOOD_TIERS: need 0 < prior < 1, 0 < eps0, eps_floor < 0.5, plants >= 1")
    return a


def open_text(path):
    with open(path, "rb") as fh:
        magic = fh.read(2)
    return gzip.open(path, "rt") if magic == bytes([31, 139]) else open(path)


def is_snp(ref, alt):
    return len(ref) == 1 and len(alt) == 1 and ref in "ACGTN" and alt in "ACGT" and ref != alt


class Model:
    def __init__(self, plants):
        self.plants = plants
        self.hap = 2 * plants
        self.logw = [math.lgamma(plants + 1) - math.lgamma(j + 1) - math.lgamma(plants - j + 1) + plants * math.log(0.5)
                     for j in range(plants + 1)]

    def terms(self, eps):
        """Per j: (log w_j, log p_j, log 1-p_j), and H0's (log eps, log 1-eps)."""
        t = []
        for j in range(self.plants + 1):
            f = j / self.hap
            p = f * (1 - eps) + (1 - f) * eps
            t.append((self.logw[j], math.log(p), math.log1p(-p)))
        return t, (math.log(eps), math.log1p(-eps))

    @staticmethod
    def llr_pool(n, a, terms):
        if n == 0:
            return 0.0
        t, (l0p, l0q) = terms
        v = [lw + a * lp + (n - a) * lq for lw, lp, lq in t]
        m = max(v)
        return m + math.log(sum(math.exp(x - m) for x in v)) - (a * l0p + (n - a) * l0q)


def binom_sf_half(n, a):
    """P(X >= a), X ~ Bin(n, 1/2)."""
    if a <= 0:
        return 1.0
    lc = [math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1) - n * math.log(2) for k in range(a, n + 1)]
    m = max(lc)
    return min(1.0, math.exp(m) * sum(math.exp(x - m) for x in lc))


def header_field(f):
    """One field of a `bcftools query -H` header: '#[1]CHROM' / '# [1]CHROM' -> 'CHROM', '[5]S_2A_3:AD' -> 'S_2A_3'."""
    f = f.lstrip("#").strip()
    if f.startswith("[") and "]" in f:
        f = f[f.index("]") + 1:]
    return f[:-3] if f.endswith(":AD") else f


def read_counts_table(path):
    """ALLELE_COUNTS table -> (samples, {(chrom, pos): (ref, [alts], [[ad...] per sample])})."""
    rows = {}
    with open_text(path) as fh:
        header = [header_field(f) for f in fh.readline().rstrip(NL).split(TAB)]
        header[:4] = [f.lower() for f in header[:4]]
        if header[:4] != ["chrom", "pos", "ref", "alt"]:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: {path}: header must start CHROM POS REF ALT, got {header[:4]}")
        samples = header[4:]
        for line in fh:
            x = line.rstrip(NL).split(TAB)
            if len(x) != len(header):
                sys.exit(f"POOLED_LIKELIHOOD_TIERS: {path}: {len(x)} fields, header has {len(header)}")
            alts = [] if x[3] in (".", "") else x[3].split(",")
            ads = []
            for cell in x[4:]:
                ads.append([int(v) if v not in (".", "") else 0 for v in cell.split(",")] if cell not in (".", "") else [0])
            rows[(x[0], int(x[1]))] = (x[2], alts, ads)
    return samples, rows


def table_counts(entry, ref, alt, n_samples):
    if entry is None or entry[0] != ref:
        return [(0, 0)] * n_samples, entry is not None
    _, alts, ads = entry
    ai = alts.index(alt) + 1 if alt in alts else None
    out = []
    for ad in ads:
        r = ad[0] if ad else 0
        k = ad[ai] if ai is not None and ai < len(ad) else 0
        out.append((r + k, k))
    return out, False


def read_crisp_vcf(path, info):
    pools, recs = None, []
    with open_text(path) as fh:
        for line in fh:
            if line.startswith("##"):
                continue
            if line.startswith("#"):
                pools = line.rstrip(NL).split(TAB)[9:]
                continue
            if pools is None:
                sys.exit(f"POOLED_LIKELIHOOD_TIERS: {path}: record before #CHROM")
            info["records_in"] += 1
            x = line.rstrip(NL).split(TAB)
            if not is_snp(x[3], x[4]):
                info["skipped_not_biallelic_snp"] += 1
                continue
            fmt = x[8].split(":")
            idx = [fmt.index(k) for k in ("ADf", "ADr", "ADb") if k in fmt]
            if not idx:
                info["skipped_no_AD"] += 1
                continue
            cnt = []
            for s in x[9:]:
                v = s.split(":")
                r = k = 0
                for i in idx:
                    if i < len(v) and "," in v[i]:
                        q = v[i].split(",")
                        r += int(q[0]) if q[0] not in (".", "") else 0
                        k += int(q[1]) if q[1] not in (".", "") else 0
                cnt.append((r + k, k))
            recs.append((x[0], int(x[1]), x[3], x[4], cnt))
    if pools is None:
        sys.exit(f"POOLED_LIKELIHOOD_TIERS: {path}: no #CHROM line")
    return pools, recs


def read_sites(paths, info):
    sites, seen = [], set()
    for p in paths:
        with open_text(p) as fh:
            for line in fh:
                x = line.rstrip(NL).split(TAB)
                if len(x) < 4 or not x[1].isdigit():
                    continue
                key = (x[0], int(x[1]), x[2], x[3])
                if key in seen:
                    continue
                seen.add(key)
                info["records_in"] += 1
                if not is_snp(x[2], x[3]):
                    info["skipped_not_biallelic_snp"] += 1
                    continue
                sites.append(key)
    return sorted(sites, key=lambda s: (s[0], s[1], s[2], s[3]))


def load_annotation(path):
    s = set()
    with open_text(path) as fh:
        for line in fh:
            x = line.split()
            if len(x) >= 4 and x[1].isdigit():
                s.add((x[0], int(x[1]), x[2], x[3]))
    return s


def main():
    a = parse_args()
    info = Counter()
    label = REGION.replace(":", "_")

    smap, taxon, role_of = {}, {}, {}
    for row in SAMPLE_MAP:
        if len(row) != 4:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: sample map rows are [sample, donor, taxon, role], got {row}")
        s, d, t, r = (str(v) for v in row)
        if r not in ROLES:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: sample {s}: role {r} not in {ROLES}")
        if s in smap:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: sample {s} twice in the sample map")
        if role_of.setdefault(d, r) != r:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: donor {d} has samples of roles {role_of[d]} and {r}")
        smap[s] = d
        taxon.setdefault(d, t)

    fmt = a.input_format
    if fmt == "auto":
        fmt = "crisp_vcf" if len(CALLS) == 1 and (CALLS[0].endswith(".vcf.gz") or CALLS[0].endswith(".vcf")) else "counts"

    tables = []  # (samples, rows)
    if fmt == "crisp_vcf":
        if len(CALLS) != 1:
            sys.exit(f"POOLED_LIKELIHOOD_TIERS: crisp_vcf input takes one VCF, got {CALLS}")
        pools, recs = read_crisp_vcf(CALLS[0], info)
        for p in EXTRA:
            tables.append(read_counts_table(p))
        pools = list(pools)
        for samples, _ in tables:
            pools += samples
        for i, (c, pos, ref, alt, cnt) in enumerate(recs):
            for samples, rows in tables:
                add, mism = table_counts(rows.get((c, pos)), ref, alt, len(samples))
                info["extra_ref_mismatch"] += mism
                cnt.extend(add)
    else:
        if not SITES:
            sys.exit("POOLED_LIKELIHOOD_TIERS: counts input needs a site list (chrom pos ref alt)")
        sites = read_sites(SITES, info)
        for p in CALLS + EXTRA:
            tables.append(read_counts_table(p))
        pools = [s for samples, _ in tables for s in samples]
        recs = []
        for c, pos, ref, alt in sites:
            cnt = []
            for samples, rows in tables:
                add, mism = table_counts(rows.get((c, pos)), ref, alt, len(samples))
                info["table_ref_mismatch"] += mism
                cnt.extend(add)
            if any(n > 0 for n, _ in cnt):
                recs.append((c, pos, ref, alt, cnt))
            else:
                info["sites_without_reads"] += 1

    if len(set(pools)) != len(pools):
        sys.exit(f"POOLED_LIKELIHOOD_TIERS: a pool appears twice across the inputs: {sorted(p for p in pools if pools.count(p) > 1)}")
    missing = [p for p in pools if p not in smap]
    if missing:
        sys.exit(f"POOLED_LIKELIHOOD_TIERS: pools not in the sample map: {missing}")

    donors = sorted({smap[p] for p in pools})
    dpools = {d: [i for i, p in enumerate(pools) if smap[p] == d] for d in donors}
    called = sorted(d for d in donors if role_of[d] == "bc1_sample")
    expected_called = sorted({d for d in smap.values() if role_of[d] == "bc1_sample"})
    if called != expected_called:
        sys.exit(f"POOLED_LIKELIHOOD_TIERS: bc1_sample donors in the map {expected_called} but pools found for {called}")
    zero_eligible = [d for d in donors if role_of[d] != "witness" or a.witness_zero_class]

    annots = []
    if len(ANNOT_NAMES) != len(ANNOT_FILES):
        sys.exit(f"POOLED_LIKELIHOOD_TIERS: {len(ANNOT_NAMES)} annotation names, {len(ANNOT_FILES)} files")
    for name, path in zip(ANNOT_NAMES, ANNOT_FILES):
        annots.append((str(name), load_annotation(path)))

    totals = [sum(n for n, _ in r[4]) for r in recs]
    med = statistics.median(totals) if totals else 0
    model = Model(a.plants)
    terms0 = model.terms(a.eps0)
    logit_prior = math.log(a.prior / (1 - a.prior))

    cols = ["chrom", "pos", "ref", "alt", "n", "a", "n_pools", "n_pools_alt", "eps", "n0", "a0", "self_in_zero", "LLR",
            "logodds", "posterior", "tier", "flags"] + [f"in_{nm}" for nm, _ in annots] + ["pool_counts"]
    out = {d: gzip.open(f"{d}.{label}.sites.tsv.gz", "wt") for d in called}
    for d in called:
        out[d].write(TAB.join(cols) + NL)
    summ = {d: Counter() for d in called}
    poolqc = [[0, 0, 0, 0] for _ in pools]
    hard = {"hidepth", "af_gt_half"}

    for (c, pos, ref, alt, cnt), total in zip(recs, totals):
        hidepth = total > a.hidepth_factor * med
        llr0 = {d: sum(model.llr_pool(cnt[i][0], cnt[i][1], terms0) for i in dpools[d]) for d in zero_eligible}
        zero = [d for d in zero_eligible if llr0[d] < a.zero_class_llr]
        n0 = sum(cnt[i][0] for d in zero for i in dpools[d])
        a0 = sum(cnt[i][1] for d in zero for i in dpools[d])
        if n0 >= a.zero_class_min_reads:
            eps, no_zero = max((a0 + 0.5) / (n0 + 1), a.eps_floor), False
        else:
            eps, no_zero = a.eps0, True
        terms = model.terms(eps)
        key = (c, pos, ref, alt)
        in_annot = [int(key in s) for _, s in annots]

        for i, (n, k) in enumerate(cnt):
            q = poolqc[i]
            q[0] += n > 0
            q[1] += k
            q[2] += n - k
            if n >= a.af_gt_half_min_depth and 2 * k > n and binom_sf_half(n, k) < a.af_gt_half_p:
                q[3] += 1

        for d in called:
            ps = dpools[d]
            n = sum(cnt[i][0] for i in ps)
            k = sum(cnt[i][1] for i in ps)
            if n == 0 and not a.keep_zero_depth:
                continue
            npa = sum(1 for i in ps if cnt[i][1] > 0)
            nwith = sum(1 for i in ps if cnt[i][0] > 0)
            llr = sum(model.llr_pool(cnt[i][0], cnt[i][1], terms) for i in ps)
            logodds = llr + logit_prior
            post = 1 / (1 + math.exp(-logodds)) if logodds > -700 else 0.0
            flags = []
            if hidepth:
                flags.append("hidepth")
            if n >= a.af_gt_half_min_depth and 2 * k > n and binom_sf_half(n, k) < a.af_gt_half_p:
                flags.append("af_gt_half")
            if len(ps) == 1:
                flags.append("single_sample")
            elif (any(cnt[i][1] >= a.inconsistent_min_alt for i in ps)
                  and any(cnt[i][0] >= a.inconsistent_min_depth and cnt[i][1] == 0 for i in ps)):
                flags.append("inconsistent")
            if no_zero:
                flags.append("no_zero_class")
            fs = set(flags)
            pools_ok = npa >= a.a_min_pools_alt or (a.a_single_pool_min_alt > 0 and len(ps) <= a.a_single_pool_max_pools
                                                    and npa >= 1 and k >= a.a_single_pool_min_alt)
            if llr >= a.llr_a and pools_ok and not fs & (hard | {"inconsistent"}):
                tier = "A"
            elif llr >= a.llr_b and not fs & hard:
                tier = "B"
            elif llr >= a.llr_c:
                tier = "C"
            elif llr <= a.llr_ref and n >= a.ref_min_depth and nwith >= a.ref_min_pools:
                tier = "ref"
            else:
                tier = "-"
            s = summ[d]
            s[tier] += 1
            s["tested"] += 1
            for (nm, _), hit in zip(annots, in_annot):
                s[f"{tier}_in_{nm}"] += hit
            row = [c, str(pos), ref, alt, str(n), str(k), str(len(ps)), str(npa), repr(eps), str(n0), str(a0),
                   str(int(d in zero)), repr(llr), repr(logodds), f"{post:.6f}", tier, ",".join(flags) or "."]
            row += [str(h) for h in in_annot]
            row.append(";".join(f"{pools[i]}:{cnt[i][1]}/{cnt[i][0]}" for i in ps))
            out[d].write(TAB.join(row) + NL)
    for d in called:
        out[d].close()

    with open(f"{PREFIX}.summary.tsv", "w") as fh:
        hdr = ["donor", "taxon", "n_pools", "tested", "A", "B", "C", "ref", "-"]
        hdr += [f"{t}_in_{nm}" for nm, _ in annots for t in ("A", "B", "C")]
        fh.write(TAB.join(hdr) + NL)
        for d in called:
            s = summ[d]
            row = [d, taxon[d], str(len(dpools[d])), str(s["tested"])] + [str(s[t]) for t in ("A", "B", "C", "ref", "-")]
            row += [str(s[f"{t}_in_{nm}"]) for nm, _ in annots for t in ("A", "B", "C")]
            fh.write(TAB.join(row) + NL)

    with open(f"{PREFIX}.pool_qc.tsv", "w") as fh:
        fh.write(TAB.join(["pool", "donor", "role", "sites_with_depth", "alt_reads", "ref_reads", "alt_frac",
                           "sites_af_gt_half"]) + NL)
        for p, q in zip(pools, poolqc):
            fh.write(TAB.join([p, smap[p], role_of[smap[p]], str(q[0]), str(q[1]), str(q[2]),
                               f"{q[1] / max(q[1] + q[2], 1):.6f}", str(q[3])]) + NL)

    with open(f"{PREFIX}.run_info.txt", "w") as fh:
        fh.write(f"prefix{TAB}{PREFIX}{NL}region{TAB}{REGION}{NL}input_format{TAB}{fmt}{NL}")
        fh.write(f"calls{TAB}{','.join(CALLS)}{NL}extra_counts{TAB}{','.join(EXTRA) or '-'}{NL}sites{TAB}{','.join(SITES) or '-'}{NL}")
        fh.write(f"records_scored{TAB}{len(recs)}{NL}pools{TAB}{len(pools)}{NL}donors{TAB}{','.join(donors)}{NL}")
        fh.write(f"called_donors{TAB}{','.join(called)}{NL}zero_class_donors{TAB}{','.join(zero_eligible)}{NL}")
        fh.write(f"median_total_depth{TAB}{med}{NL}")
        for k in sorted(info):
            fh.write(f"{k}{TAB}{info[k]}{NL}")
        for k, v in sorted(vars(a).items()):
            fh.write(f"option_{k}{TAB}{v}{NL}")
        for nm, s in annots:
            fh.write(f"annotation_{nm}{TAB}{len(s)} sites{NL}")
    print(f"POOLED_LIKELIHOOD_TIERS {PREFIX}: {len(recs)} records, {len(pools)} pools, donors {donors}, "
          f"median depth {med}; " + "; ".join(f"{d}: A {summ[d]['A']} B {summ[d]['B']} C {summ[d]['C']} ref {summ[d]['ref']}"
                                              for d in called), file=sys.stderr)

    with open(f"{PREFIX}.pooled_likelihood_tiers.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
