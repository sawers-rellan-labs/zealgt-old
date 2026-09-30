#!/usr/bin/env python3
"""Writes the tiny blind-panel fixture used by the COVERAGE_QC, RELATEDNESS_QC and DONOR_CONTENT_QC module tests.

Run from this directory: python3 make_panel_fixture.py (deterministic; seed 7). Writes
  panel.tsv                chrom pos ref alt (no header), 60 sites on chr10
  D1.panel.ad.tsv.gz       bcftools query -H layout (%CHROM %POS %REF %ALT [%AD]) for donor D1: lines L1-L5, BC1 pools B1-B2
  D2.panel.ad.tsv.gz       donor D2: lines M1-M5, BC1 pools C1-C2
  b73.panel.ad.tsv.gz      B73 control K1
  sample_map.json          [[sample, role, donor], ...]
Truth: sites 1-30 carry D1's ALT allele, 31-60 D2's. Every line carries its donor's allele at a fixed shared block of its
donor's sites (siblings share segments) plus a few private ones; L4 is a seed mix-up (it carries D2's block, recorded
under D1); L5 is B73-contaminated (no donor allele at all). Lines get 0-3 reads per site, pools 4-8.
"""
import gzip
import io
import json
import random

TAB = "\t"
rng = random.Random(7)
BASES = "ACGT"
N = 60
panel = []
for i in range(N):
    pos = 1000 + 37 * i
    ref = BASES[i % 4]
    alt = BASES[(i + 1) % 4]
    panel.append(("chr10", pos, ref, alt))
D1_SITES = set(range(0, 30))
D2_SITES = set(range(30, 60))
BLOCK = {"D1": set(range(0, 18)), "D2": set(range(30, 48))}   # shared donor segment of each donor's lines


samples = []  # (name, role, donor, table, carried sites -> ALT allele fraction)
for d, own, table in (("D1", D1_SITES, "D1"), ("D2", D2_SITES, "D2")):
    pre = "L" if d == "D1" else "M"
    for k in range(1, 6):
        name = f"{pre}{k}"
        priv = set(rng.sample(sorted(own - BLOCK[d]), 4))
        carried = {s: 0.5 for s in BLOCK[d] | priv}
        if name == "L4":
            carried = {s: 0.5 for s in BLOCK["D2"]}
        if name == "L5":
            carried = {}
        samples.append((name, "line", d, table, carried))
    pre = "B" if d == "D1" else "C"
    for k in (1, 2):
        samples.append((f"{pre}{k}", "bc1_sample", d, table, {s: 0.25 for s in own}))
samples.append(("K1", "b73_control", "", "b73", {}))

for table in ("D1", "D2", "b73"):
    rows = [s for s in samples if s[3] == table]
    with gzip.GzipFile(f"{table}.panel.ad.tsv.gz", "wb", mtime=0) as raw, io.TextIOWrapper(raw) as out:
        hdr = ["# [1]CHROM", "[2]POS", "[3]REF", "[4]ALT"] + [f"[{5 + i}]{s[0]}:AD" for i, s in enumerate(rows)]
        out.write(TAB.join(hdr) + "\n")
        for i, (c, pos, ref, alt) in enumerate(panel):
            ads = []
            any_alt = False
            for name, role, d, _, carried in rows:
                depth = rng.randint(0, 3) if role == "line" else rng.randint(4, 8)
                if name == "K1":
                    depth = rng.randint(3, 6)
                f = carried.get(i, 0.0)
                a = sum(1 for _ in range(depth) if rng.random() < f)
                ads.append((depth - a, a))
                any_alt = any_alt or a > 0
            alts = f"{alt},<*>" if any_alt else "<*>"
            cols = [f"{r},{a},0" if any_alt else f"{r},0" for r, a in ads]
            if all(r + a == 0 for r, a in ads):
                continue
            out.write(TAB.join([c, str(pos), ref, alts] + cols) + "\n")

with open("panel.tsv", "w") as out:
    for c, pos, ref, alt in panel:
        out.write(TAB.join([c, str(pos), ref, alt]) + "\n")
with open("sample_map.json", "w") as out:
    json.dump([[s[0], s[1], s[2]] for s in samples], out)
print(f"{len(panel)} panel sites, {len(samples)} samples")
