#!/usr/bin/env python3
"""Write the POOLED_LIKELIHOOD_TIERS test fixtures (run from the repository root):
    python3 modules/local/pooled_likelihood_tiers/tests/data/write_test_tables.py
Donor Zx.0540_P3 = BC1 pools S_2A_3, S_2A_11; witness Zx0540_P3_BC2S3; B73 controls B73_ERR3288215, B73_skim10.
Sites (ref, alt reads per pool; the case each tests):
  1001 A>C  S_2A_3 20/5 (ADf 8,3 + ADr 7,2), S_2A_11 20/4; B73 30/0, 30/0 (only '<*>' seen)     tier A, eps from B73
  1500 G>T  40/0, 30/0; B73 30/0, 25/0                                                           tier ref
  2001 T>A  12/10, 12/10; B73 20/0, 20/0                                                         af_gt_half -> C
  2500 C>G  20/6, 20/0; B73 20/1, 20/0                                                           inconsistent -> B
  3001 A>C  200/50, 200/50; B73 150/0, 150/1 (C listed after G in the table's ALT)             hidepth -> C
  3500 C>G  10/3, 10/2; no B73 row                                                               no_zero_class
  4001 AT>A (indel), 4500 A>C,G (multi-allelic)                                                  skipped
Files: calls.vcf.gz (CRISP layout, BGZF), b73.ad.tsv.gz, bc1.ad.tsv.gz (the BC1 pools as an ALLELE_COUNTS table; the
tables carry the raw bcftools query -H header, b73 in the '# [1]CHROM' style of bcftools 1.21),
sites.tsv (the site list of counts mode), d2.ad.tsv.gz (a second donor Zx.0570_P2, pool S_3A_1: 0 ALT everywhere, and no
reads at 3500), annot.tsv (an annotation: 1001 and 2500).
"""
import gzip
import os
import subprocess

TAB = chr(9)
NL = chr(10)
D = "modules/local/pooled_likelihood_tiers/tests/data"

SITES = [
    # pos, ref, alt, S_2A_3 (ref, alt, [ADf split]), S_2A_11, witness, B73 table cells (or None)
    (1001, "A", "C", (15, 5, (8, 3)), (16, 4, None), (9, 1), ("<*>", "30,0", "30,0")),
    (1500, "G", "T", (40, 0, None), (30, 0, None), (7, 1), ("<*>", "30,0", "25,0")),
    (2001, "T", "A", (2, 10, None), (2, 10, None), (5, 1), ("<*>", "20,0", "20,0")),
    (2500, "C", "G", (14, 6, None), (20, 0, None), (5, 1), ("G,<*>", "20,1,0", "20,0,0")),
    (3001, "A", "C", (150, 50, None), (150, 50, None), (18, 2), ("G,C,<*>", "150,0,0,0", "150,0,1,0")),
    (3500, "C", "G", (7, 3, None), (8, 2, None), (4, 1), None),
]


def query_header(samples, space=False):
    """The `bcftools query -H` header of ALLELE_COUNTS ('#[1]CHROM', or '# [1]CHROM' with space=True)."""
    f = ["CHROM", "POS", "REF", "ALT"] + [f"{s}:AD" for s in samples]
    return ("# " if space else "#") + TAB.join(f"[{i}]{x}" for i, x in enumerate(f, 1))


def cell(r, a, split):
    if split:
        f_r, f_a = split
        return f"0/0:{r + a}:{f_r},{f_a}:{r - f_r},{a - f_a}:0,0"
    return f"0/0:{r + a}:{r},{a}:0,0:0,0"


def main():
    hdr = ["##fileformat=VCFv4.1", "##source=CRISP-like test fixture (zealgt POOLED_LIKELIHOOD_TIERS)",
           "##contig=<ID=chrA,length=20000>"]
    for k in ("ADf", "ADr", "ADb"):
        hdr.append(f'##FORMAT=<ID={k},Number=.,Type=Integer,Description="Allele depth ({k})">')
    hdr.append(TAB.join(["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT",
                         "S_2A_3", "S_2A_11", "Zx0540_P3_BC2S3"]))
    lines = list(hdr)
    for pos, ref, alt, s1, s2, w, _ in SITES:
        lines.append(TAB.join(["chrA", str(pos), ".", ref, alt, "30", "PASS", ".", "GT:DP:ADf:ADr:ADb",
                               cell(*s1), cell(*s2), cell(w[0], w[1], None)]))
    lines.append(TAB.join(["chrA", "4001", ".", "AT", "A", "30", "PASS", ".", "GT:DP:ADf:ADr:ADb",
                           cell(10, 2, None), cell(10, 1, None), cell(3, 1, None)]))
    lines.append(TAB.join(["chrA", "4500", ".", "A", "C,G", "30", "PASS", ".", "GT:DP:ADf:ADr:ADb",
                           "0/0:12:10,1,1:0,0,0:0,0,0", "0/0:10:10,0,0:0,0,0", "0/0:3:2,1,0:0,0,0"]))
    lines.sort(key=lambda l: (not l.startswith("#"), 0 if l.startswith("#") else int(l.split(TAB)[1])))
    vcf = os.path.join(D, "calls.vcf")
    with open(vcf, "w") as out:
        out.write(NL.join(lines) + NL)
    subprocess.run(["bgzip", "-f", vcf], check=True)

    with gzip.open(os.path.join(D, "b73.ad.tsv.gz"), "wt") as out:
        out.write(query_header(["B73_ERR3288215", "B73_skim10"], space=True) + NL)  # bcftools 1.21 style
        for pos, ref, alt, _, _, _, b in SITES:
            if b:
                out.write(TAB.join(["chrA", str(pos), ref, b[0], b[1], b[2]]) + NL)

    with gzip.open(os.path.join(D, "bc1.ad.tsv.gz"), "wt") as out:
        out.write(query_header(["S_2A_3", "S_2A_11"]) + NL)
        for pos, ref, alt, s1, s2, _, _ in SITES:
            out.write(TAB.join(["chrA", str(pos), ref, f"{alt},<*>", f"{s1[0]},{s1[1]},0", f"{s2[0]},{s2[1]},0"]) + NL)

    with gzip.open(os.path.join(D, "d2.ad.tsv.gz"), "wt") as out:
        out.write(query_header(["S_3A_1"]) + NL)
        for pos, ref, alt, _, _, _, _ in SITES:
            if pos != 3500:
                out.write(TAB.join(["chrA", str(pos), ref, "<*>", "40,0"]) + NL)

    with open(os.path.join(D, "sites.tsv"), "w") as out:
        for pos, ref, alt, _, _, _, _ in SITES:
            out.write(TAB.join(["chrA", str(pos), ref, alt]) + NL)
        out.write(TAB.join(["chrA", "4001", "AT", "A"]) + NL)

    with open(os.path.join(D, "annot.tsv"), "w") as out:
        out.write(TAB.join(["chrA", "1001", "A", "C"]) + NL)
        out.write(TAB.join(["chrA", "2500", "C", "G"]) + NL)


if __name__ == "__main__":
    main()
