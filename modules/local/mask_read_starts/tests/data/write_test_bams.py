#!/usr/bin/env python3
"""Write the small BAM fixtures of the variant_discovery module tests (MASK_READ_STARTS, WITNESS_POOL, ALLELE_COUNTS).

Run from the repository root (needs samtools on PATH):
    python3 modules/local/mask_read_starts/tests/data/write_test_bams.py
Reads are cut from tests/fixtures/ref/tiny.fa (chrA), so they align without mismatches except where an ALT base is set.

mask_read_starts/tests/data/
  s1.bam(.bai)  one @RG (ID:old SM:oldname); records named after what the mask should do with mask [3, 2]:
                r1_fwd (0x40 forward: first 3 QUAL '!'), r1_rev (0x40|0x10: last 3), r2_fwd (0x80: first 2), r2_rev (last 2),
                secondary (0x100: unchanged), unpaired (neither flag: mask_r1 = 3, first 3), softclip (5S25M, forward R1:
                first 3, inside the clip), noqual (QUAL '*': unchanged), outside (chrA:15001, outside the test BED: dropped)
  s2.bam(.bai)  no @RG; two forward unpaired reads (mask [0, 0]: unchanged)
  region.bed    chrA 0 10000
allele_counts/tests/data/  (and crisp/tests/data/: Zx0540_P3_BC2S3.bam = p1 + p2 reads under one RG, the CRISP witness; region.bed chrA 900 3100)
  p1.bam(.bai)  SM p1. chrA:1001 10 reads, 3 ALT; chrA:2001 5 reads, 5 ALT; chrA:3001 6 reads, 2 ALT, plus 2 ALT reads at
                MAPQ 10 and 1 ALT duplicate (0x400), which -q 20 and the default --ff drop
  p2.bam(.bai)  SM p2. chrA:1001 8 reads, 0 ALT; chrA:3001 4 reads, 0 ALT, each with a 2-bp insertion right after 3001
                (with -I no indel record replaces the SNP counts)
  sites.tsv     chrA 1001/2001/3001/4001 with their REF and the ALT used here (4001 has no reads), plus a header line
                (the counter must skip it)
"""
import os
import subprocess

REPO = os.getcwd()
FA = os.path.join(REPO, "tests/fixtures/ref/tiny.fa")
TAB = chr(9)
NL = chr(10)
L = 30


def read_fasta(path):
    seqs, name = {}, None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith(">"):
                name = line[1:].split()[0]
                seqs[name] = []
            elif name:
                seqs[name].append(line)
    return {k: "".join(v).upper() for k, v in seqs.items()}


REF = read_fasta(FA)["chrA"]


def alt_of(base):
    return "A" if base != "A" else "C"


def rec(name, flag, pos, seq=None, qual=None, cigar=f"{L}M", mapq=60):
    """pos 1-based leftmost aligned base."""
    if seq is None:
        seq = REF[pos - 1:pos - 1 + L]
    if qual is None:
        qual = "I" * len(seq)
    return TAB.join([name, str(flag), "chrA", str(pos), str(mapq), cigar, "*", "0", "0", seq, qual])


def with_alt(pos, site):
    """A read starting at pos, carrying the ALT base at 1-based site."""
    seq = list(REF[pos - 1:pos - 1 + L])
    i = site - pos
    seq[i] = alt_of(REF[site - 1])
    return "".join(seq)


def write_bam(path, header, records):
    sam = path[:-4] + ".sam"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(sam, "w") as out:
        out.write(header)
        for r in records:
            out.write(r + NL)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(["samtools", "sort", "--no-PG", "-o", path, sam], check=True)
    subprocess.run(["samtools", "index", path], check=True)
    os.remove(sam)


def main():
    hd = f"@HD{TAB}VN:1.6{TAB}SO:coordinate{NL}@SQ{TAB}SN:chrA{TAB}LN:20000{NL}@SQ{TAB}SN:chrB{TAB}LN:12000{NL}"

    d = os.path.join(REPO, "modules/local/mask_read_starts/tests/data")
    s1 = [
        rec("r1_fwd", 99, 101),
        rec("r1_rev", 83, 201),
        rec("r2_fwd", 163, 301),
        rec("r2_rev", 147, 401),
        rec("secondary", 355, 501),
        rec("unpaired", 0, 601),
        rec("softclip", 99, 706, seq=REF[700:730], cigar="5S25M"),
        rec("noqual", 0, 801, qual="*"),
        rec("outside", 0, 15001),
    ]
    write_bam(os.path.join(d, "s1.bam"), hd + f"@RG{TAB}ID:old{TAB}SM:oldname{NL}", [r + f"{TAB}RG:Z:old" for r in s1])
    write_bam(os.path.join(d, "s2.bam"), hd, [rec("a", 0, 1001), rec("b", 0, 1101)])
    with open(os.path.join(d, "region.bed"), "w") as out:
        out.write(f"chrA{TAB}0{TAB}10000{NL}")

    d = os.path.join(REPO, "modules/local/allele_counts/tests/data")
    p1, p2 = [], []
    for k in range(10):  # chrA:1001, 3 ALT of 10
        start = 1001 - 5 - k
        p1.append(rec(f"p1_1001_{k}", 0, start, seq=with_alt(start, 1001) if k < 3 else None))
    for k in range(5):  # chrA:2001, 5 ALT of 5
        start = 2001 - 5 - k
        p1.append(rec(f"p1_2001_{k}", 0, start, seq=with_alt(start, 2001)))
    for k in range(6):  # chrA:3001, 2 ALT of 6
        start = 3001 - 5 - k
        p1.append(rec(f"p1_3001_{k}", 0, start, seq=with_alt(start, 3001) if k < 2 else None))
    for k in range(2):  # MAPQ 10 ALT reads (dropped by -q 20)
        start = 3001 - 12 - k
        p1.append(rec(f"p1_3001_lowmq_{k}", 0, start, seq=with_alt(start, 3001), mapq=10))
    start = 3001 - 14  # duplicate ALT read (dropped by mpileup's default --ff DUP)
    p1.append(rec("p1_3001_dup", 1024, start, seq=with_alt(start, 3001)))
    for k in range(8):  # chrA:1001, 0 ALT of 8
        p2.append(rec(f"p2_1001_{k}", 0, 1001 - 5 - k))
    for k in range(4):  # chrA:3001, REF, then a 2-bp insertion after 3001
        start = 3001 - 9 - k
        m1 = 3001 - start + 1
        seq = REF[start - 1:3001] + "TT" + REF[3001:3001 + (L - m1 - 2)]
        p2.append(rec(f"p2_3001_ins_{k}", 0, start, seq=seq, cigar=f"{m1}M2I{L - m1 - 2}M"))
    write_bam(os.path.join(d, "p1.bam"), hd + f"@RG{TAB}ID:p1{TAB}SM:p1{NL}", [r + f"{TAB}RG:Z:p1" for r in p1])
    write_bam(os.path.join(d, "p2.bam"), hd + f"@RG{TAB}ID:p2{TAB}SM:p2{NL}", [r + f"{TAB}RG:Z:p2" for r in p2])
    c = os.path.join(REPO, "modules/local/crisp/tests/data")
    write_bam(os.path.join(c, "Zx0540_P3_BC2S3.bam"), hd + f"@RG{TAB}ID:W{TAB}SM:Zx0540_P3_BC2S3{NL}",
              [r + f"{TAB}RG:Z:W" for r in p1 + p2])
    with open(os.path.join(c, "region.bed"), "w") as out:
        out.write(f"chrA{TAB}900{TAB}3100{NL}")
    with open(os.path.join(d, "sites.tsv"), "w") as out:
        out.write(f"chrom{TAB}pos{TAB}ref{TAB}alt{NL}")
        for site in (1001, 2001, 3001, 4001):
            out.write(f"chrA{TAB}{site}{TAB}{REF[site - 1]}{TAB}{alt_of(REF[site - 1])}{NL}")


if __name__ == "__main__":
    main()
