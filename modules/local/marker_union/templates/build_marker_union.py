#!/usr/bin/env python3
"""Union of the tier-A sites of a donor set in one region (MARKER_UNION, stage 5; PLAN §3 row 5, math supplement Text S5).

Nextflow module template (modules/local/marker_union/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (the template engine
would read them); tab and newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions can be
imported by the unit tests (tests/test_build_marker_union.py). Standard library only.

Inputs
  step4/<donor>.<region>.sites.tsv.gz   step-4 tables of the run's donors (POOLED_LIKELIHOOD_TIERS; needs chrom pos ref alt
                                        tier). A table is assigned to the longest run donor whose name + "." starts its
                                        file name.
  reference/<i>/<any name>              read-only step-4 tables of reference donors (design §2.4, `reference_donor_tables`),
                                        staged in the order of the reference donor list (stageAs 'reference/?/*'), so their
                                        file names do not matter. They are clipped to the region (a zealbc1 table covers
                                        the whole chromosome).
Key = (chrom, pos, ref, alt), biallelic SNVs only. A position with two different ALT alleles among the tier-A sets is
multiallelic (flag 1 in every row at it) and is dropped downstream (PLAN §3 row 5).

Outputs
  <prefix>.tsv.gz        chrom pos ref alt n_donors donors multiallelic donor_kind ref_donors
                         donors = tier-A carriers (sorted); donor_kind = run|reference per carrier (same order);
                         ref_donors = reference donors whose own table calls the allele tier `ref` there (only REF from their
                         own reads, as gap_ref in zealbc1 dhd_bayes.py), '.' if none. Run donors' REF calls come from the
                         joint recount in stage 6, not from here.
  <prefix>.union_sites.tsv   chrom pos ref alt of the non-multiallelic alleles, no header: the site list of the stage-6
                         counts (ALLELE_COUNTS; replaces a separate UNION_SITES task)
  <prefix>.per_donor.tsv donor donor_kind table table_sha256 tierA shared private union_alleles n_gaps multiallelic_own
                         n_gaps = non-multiallelic union alleles the donor does not carry (what stage 6 fills)
  <prefix>.marker_union.versions.yml
A run donor with 0 gap sites is logged as `WARN ... 0 gap sites: stage 6 has nothing to fill` (one run donor and no reference
tables gives exactly that; design §2.4). ext.args: none (unknown options are refused).
"""
import argparse
import gzip
import io
import hashlib
import json
import os
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)


def log(msg):
    sys.stderr.write("[marker_union] " + msg + NL)


def gz_write(path):
    """Text writer of a gzip file with mtime 0, so equal content gives equal bytes (snapshots, reruns)."""
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), encoding="utf-8")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def parse_region(region):
    """'chr10' -> ('chr10', 1, None); 'chr10:1-20000000' -> ('chr10', 1, 20000000) (1-based, inclusive)."""
    if ":" not in region:
        return region, 1, None
    chrom, span = region.rsplit(":", 1)
    start, end = span.replace(",", "").split("-")
    start, end = int(start), int(end)
    if start < 1 or end < start:
        raise ValueError(f"bad region '{region}'")
    return chrom, start, end


def in_region(chrom, pos, region):
    c, s, e = region
    return chrom == c and pos >= s and (e is None or pos <= e)


def assign_tables(files, donors):
    """{donor: file}: each file goes to the longest donor whose name + '.' starts its basename; exactly one file per donor."""
    out = {}
    for f in files:
        base = os.path.basename(f)
        hits = [d for d in donors if base.startswith(d + ".")]
        if not hits:
            raise SystemExit(f"MARKER_UNION: table {base} matches no run donor of {donors}")
        d = max(hits, key=len)
        if d in out:
            raise SystemExit(f"MARKER_UNION: two tables for donor {d}: {os.path.basename(out[d])}, {base}")
        out[d] = f
    missing = [d for d in donors if d not in out]
    if missing:
        raise SystemExit(f"MARKER_UNION: no step-4 table for run donor(s) {missing}")
    return out


def read_step4(path, region):
    """(tier-A keys, ref-tier keys, rows read) of one step-4 table, biallelic SNVs inside the region."""
    tier_a, tier_ref, n = set(), set(), 0
    with open_text(path) as fh:
        header = fh.readline().rstrip(NL).split(TAB)
        col = {k: i for i, k in enumerate(header)}
        for need in ("chrom", "pos", "ref", "alt", "tier"):
            if need not in col:
                raise SystemExit(f"MARKER_UNION: {os.path.basename(path)} has no column '{need}' (header {header})")
        for line in fh:
            x = line.rstrip(NL).split(TAB)
            chrom, pos, ref, alt, tier = x[col["chrom"]], int(x[col["pos"]]), x[col["ref"]], x[col["alt"]], x[col["tier"]]
            if len(ref) != 1 or len(alt) != 1 or not in_region(chrom, pos, region):
                continue
            n += 1
            key = (chrom, pos, ref, alt)
            if tier == "A":
                tier_a.add(key)
            elif tier == "ref":
                tier_ref.add(key)
    return tier_a, tier_ref, n


def build_union(tier_a, tier_ref, kinds):
    """tier_a/tier_ref: {donor: set(keys)}; kinds: {donor: 'run'|'reference'}. Returns sorted union rows (dicts)."""
    carriers = {}
    for d, keys in tier_a.items():
        for k in keys:
            carriers.setdefault(k, []).append(d)
    alts_at = {}
    for k in carriers:
        alts_at.setdefault(k[:2], set()).add(k[3])
    multi = {p for p, a in alts_at.items() if len(a) > 1}
    refs = [d for d in kinds if kinds[d] == "reference"]
    rows = []
    for k in sorted(carriers, key=lambda z: (z[0], z[1], z[3])):
        ds = sorted(carriers[k])
        rd = sorted(d for d in refs if d not in ds and k in tier_ref.get(d, set()))
        rows.append({"chrom": k[0], "pos": k[1], "ref": k[2], "alt": k[3], "n_donors": len(ds), "donors": ds,
                     "multiallelic": int(k[:2] in multi), "donor_kind": [kinds[d] for d in ds], "ref_donors": rd})
    return rows


def per_donor_rows(rows, tier_a, kinds):
    out = []
    ok = [r for r in rows if not r["multiallelic"]]
    for d in kinds:
        a = tier_a[d]
        shared = sum(1 for r in rows if d in r["donors"] and r["n_donors"] > 1)
        own_multi = sum(1 for r in rows if d in r["donors"] and r["multiallelic"])
        gaps = sum(1 for r in ok if d not in r["donors"])
        out.append({"donor": d, "donor_kind": kinds[d], "tierA": len(a), "shared": shared, "private": len(a) - shared,
                    "union_alleles": len(ok), "n_gaps": gaps, "multiallelic_own": own_multi})
    return out


def write_outputs(prefix, rows, pdrows, tables):
    with gz_write(f"{prefix}.tsv.gz") as o:
        o.write(TAB.join(["chrom", "pos", "ref", "alt", "n_donors", "donors", "multiallelic", "donor_kind", "ref_donors"]) + NL)
        for r in rows:
            o.write(TAB.join([r["chrom"], str(r["pos"]), r["ref"], r["alt"], str(r["n_donors"]), ",".join(r["donors"]),
                              str(r["multiallelic"]), ",".join(r["donor_kind"]), ",".join(r["ref_donors"]) or "."]) + NL)
    with open(f"{prefix}.union_sites.tsv", "w") as o:
        for r in rows:
            if not r["multiallelic"]:
                o.write(TAB.join([r["chrom"], str(r["pos"]), r["ref"], r["alt"]]) + NL)
    cols = ["donor", "donor_kind", "table", "table_sha256", "tierA", "shared", "private", "union_alleles", "n_gaps",
            "multiallelic_own"]
    with open(f"{prefix}.per_donor.tsv", "w") as o:
        o.write(TAB.join(cols) + NL)
        for p in pdrows:
            path = tables[p["donor"]]
            p = dict(p, table=os.path.basename(path), table_sha256=sha256(path))
            o.write(TAB.join(str(p[c]) for c in cols) + NL)


def list_files(d):
    out = []
    if os.path.isdir(d):
        for root, _dirs, files in os.walk(d):
            out += [os.path.join(root, f) for f in files]
    return sorted(out)


def reference_files(ref_donors, d="reference"):
    """reference/<i>/<file>, i = 1-based position in the reference donor list."""
    out = {}
    for i, donor in enumerate(ref_donors, start=1):
        files = list_files(os.path.join(d, str(i)))
        if len(files) != 1:
            raise SystemExit(f"MARKER_UNION: reference donor {donor}: expected one table in {d}/{i}/, found {files}")
        out[donor] = files[0]
    extra = [f for f in list_files(d) if os.path.dirname(os.path.relpath(f, d)) not in {str(i) for i in range(1, len(ref_donors) + 1)}]
    if extra:
        raise SystemExit(f"MARKER_UNION: reference tables without a reference donor name: {extra}")
    return out


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    donors = json.loads('''${groovy.json.JsonOutput.toJson(donors)}''')
    ref_donors = json.loads('''${groovy.json.JsonOutput.toJson(reference_donors)}''')
    region_str = "${region}"
    ap = argparse.ArgumentParser(prog="build_marker_union.py")
    ap.parse_args(shlex.split('''${task.ext.args ?: ''}'''))

    region = parse_region(region_str)
    clash = sorted(set(donors) & set(ref_donors))
    if clash:
        raise SystemExit(f"MARKER_UNION: donor(s) {clash} are both run donors and reference donors")
    tables = assign_tables(list_files("step4"), donors)
    tables.update(reference_files(ref_donors))
    kinds = {d: "run" for d in donors}
    kinds.update({d: "reference" for d in ref_donors})
    tier_a, tier_ref = {}, {}
    for d in kinds:
        tier_a[d], tier_ref[d], n = read_step4(tables[d], region)
        log(f"{d} ({kinds[d]}): {n} biallelic rows in {region_str}, tier A {len(tier_a[d])}, tier ref {len(tier_ref[d])}"
            f" ({os.path.basename(tables[d])})")
    rows = build_union(tier_a, tier_ref, kinds)
    pdrows = per_donor_rows(rows, tier_a, kinds)
    write_outputs(prefix, rows, pdrows, tables)
    n_multi = sum(r["multiallelic"] for r in rows)
    log(f"{prefix}: union alleles {len(rows)} ({n_multi} at multiallelic positions, dropped downstream); "
        f"run donors {donors}; reference donors {ref_donors or 'none'}")
    for p in pdrows:
        log(f"{p['donor']} ({p['donor_kind']}): tier A {p['tierA']} | shared {p['shared']} | private {p['private']} | gaps {p['n_gaps']}")
        if p["donor_kind"] == "run" and p["n_gaps"] == 0:
            log(f"WARN {prefix}: donor {p['donor']} has 0 gap sites: stage 6 has nothing to fill"
                f" (run donors {len(donors)}, reference donors {len(ref_donors)})")
    with open(f"{prefix}.marker_union.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
