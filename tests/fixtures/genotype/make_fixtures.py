#!/usr/bin/env python3
"""Write the genotype-workflow test fixtures (genotype design §7.2): small, synthetic, deterministic.

    python3 tests/fixtures/genotype/make_fixtures.py [--outdir DIR] [--samtools PATH]

Standard library only, plus samtools (CRAM encoding, faidx, index; any 1.2x). Every random draw comes from one seeded
random.Random, gzip members carry mtime 0 and CRAMs are written with --no-PG, so a rerun with the same samtools writes the
same bytes (MANIFEST.tsv lists the sha256 of every file and the samtools version used). Default outdir = this directory.

What is written (paths relative to the outdir)
  ref/tiny10.fa(.fai)            reference slice: chr10 (20,000 bp; the sequence of tests/fixtures/ref/tiny.fa chrA) and
                                 chr9 (12,000 bp; chrB). Named chr10 / chr9 because RTIGER needs an integer chromosome.
  lowcopy.bed                    3 ranges on chr10 + 1 on chr9 (0-based, half-open)
  panel.tsv                      blind QC panel: 8 sites (chrom pos ref alt, no header)
  priors/mexicana.prior.tsv      mappability prior of taxon mexicana: columns c weight, 31-bin grid 0..1.5 step 0.05
  reference/Zx.9002_P1.sites.tsv.gz   read-only step-4 table of a reference donor (not called in the test runs):
                                 tier-A and tier-ref rows in the region, one multiallelic ALT, two rows outside the region
  genotype_samples_test.csv      genotype sheet (assets/schema_genotype.json): donor Zx.9001_P1, taxon mexicana;
                                 BC1_A, BC1_B (bc1_sample, mask 2/2), LINE_1..LINE_4 + LINE_LOW (line, mask 12/0),
                                 B73_CTL (b73_control, 0/0), LINE_EXCL (include FALSE, no files: excluded rows are never resolved)
  cram_store/cram_import/<id>.cram .cram.crai .CollectWgsMetrics.coverage_metrics .provenance.json
                                 the CRAM-store layout the genotype workflow reads (design §1.1); provenance markdup =
                                 'samtools markdup -d 2500' (the default markdup_args), origin.kind import
  store_seed/genotype/test/...   upstream outputs of every stage under genotype_store_key 'test' (design §1.3 layout, the
                                 real column formats of the module templates, values derived from the truth below); a
                                 per-entry test copies the kinds of the stages before its entry into its own store_stub
  truth/sites.tsv, truth/segments.tsv   the simulated truth (site classes, donor alleles, BC1 pool fractions, line segments)
  MANIFEST.tsv                   sha256 and size of every file above

Truth (region chr10:1-16000, label chr10_1-16000; run donor Zx.9001_P1, reference donor Zx.9002_P1)
  20 SNP sites inside the BED ranges. Classes:
    own     sites 0-11: Zx.9001_P1 carries ALT; BC1 pools at k/12 (k ~ Bin(6, 1/2), k >= 1 in both pools) -> tier A
    weak    sites 12-13: Zx.9001_P1 carries ALT but only BC1_A has it at 1/12 -> not tier A; Zx.9002_P1 tier A -> gap, ALT
    ronly   sites 14-17: Zx.9002_P1 tier A only; Zx.9001_P1 REF -> gap, REF / missing. Site 15: LINE_3 (x = 0 everywhere)
            carries one ALT read (review #1b: an ALT read in an x = 0 line is a zero-class read)
    none    sites 18-19: nobody (panel background)
  Shared tier A with the reference donor: 0, 3, 6, 9; site 10: the reference donor has another ALT -> multiallelic in the union.
  Reference donor tier ref at 1, 2 (its own REF calls, the m of the step-1 prior).
  Lines (x = copies of the donor segment): LINE_1 2 on 1-8000, 0 after; LINE_2 0 on 1-9000, 1 after; LINE_3 0 everywhere;
  LINE_4 0 / 2 on 4001-12000 / 0; LINE_LOW 5 read pairs (mean coverage < 0.05: fails MIN_COVERAGE).
  5' artefacts (what MASK_READ_STARTS removes): lines R1 cycles 1-12 at 15 % substitutions (batch-1 random primer), BC1 R1
  and R2 cycles 1-2 at 40 %; background error 0.2 %. Reads: 2 x 100 bp, fragment 250-350 bp, MAPQ 60, one @RG (ID = SM = id).
"""
import argparse
import csv
import gzip
import hashlib
import io
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC_FASTA = os.path.join(REPO, "tests", "fixtures", "ref", "tiny.fa")
SEED = 20260929
DONOR = "Zx.9001_P1"
REF_DONOR = "Zx.9002_P1"
DONOR_SET = "test_set"
KEY = "test"
CHROM = "chr10"
REGION = (CHROM, 1, 16000)
LABEL = "chr10_1-16000"
READ_LEN = 100
BED = [("chr10", 500, 4500), ("chr10", 5500, 10000), ("chr10", 11000, 15500), ("chr9", 1000, 6000)]
SITE_POS = [700, 1100, 1500, 2000, 2600, 3100, 3700, 4200, 5800, 6400, 7000, 7700, 8300, 9100, 9700,
            11300, 12100, 13000, 14000, 15000]
OWN, WEAK, RONLY, NONE = range(0, 12), range(12, 14), range(14, 18), range(18, 20)
SHARED = {0, 3, 6, 9}
MULTI = 10
REF_DONOR_TIER_REF = {1, 2}
B1B_SITE = 15
PANEL = [1, 4, 8, 11, 14, 16, 18, 19]
SEGMENTS = {  # line -> [(start, end, x)] on chr10, 1-based inclusive, covering the region
    "LINE_1": [(1, 8000, 2), (8001, 16000, 0)],
    "LINE_2": [(1, 9000, 0), (9001, 16000, 1)],
    "LINE_3": [(1, 16000, 0)],
    "LINE_4": [(1, 4000, 0), (4001, 12000, 2), (12001, 16000, 0)],
    "LINE_LOW": [(1, 16000, 0)],
}
# sample -> role, source, masks, read pairs, 5' artefact (cycles R1, cycles R2, rate)
SAMPLES = [
    ("BC1_A", "bc1_sample", "bc1", (2, 2), 1600, (2, 2, 0.40)),
    ("BC1_B", "bc1_sample", "bc1", (2, 2), 1600, (2, 2, 0.40)),
    ("LINE_1", "line", "bc2s3_batch1", (12, 0), 500, (12, 0, 0.15)),
    ("LINE_2", "line", "bc2s3_batch1", (12, 0), 500, (12, 0, 0.15)),
    ("LINE_3", "line", "bc2s3_batch1", (12, 0), 500, (12, 0, 0.15)),
    ("LINE_4", "line", "bc2s3_batch1", (12, 0), 500, (12, 0, 0.15)),
    ("LINE_LOW", "line", "bc2s3_batch1", (12, 0), 5, (12, 0, 0.15)),
    ("B73_CTL", "b73_control", "b73_control", (0, 0), 800, (0, 0, 0.0)),
]
EXCLUDED = ("LINE_EXCL", "line", "bc2s3_batch1", (12, 0))
BASE_ERR = 0.002
MARKDUP = "samtools markdup -d 2500"
TAB, NL = "\t", "\n"


# ---------------------------------------------------------------------------------------------------------------- helpers
def read_fasta(path):
    seqs, name = {}, None
    with open(path) as fh:
        for ln in fh:
            ln = ln.strip()
            if ln.startswith(">"):
                name = ln[1:].split()[0]
                seqs[name] = []
            elif name:
                seqs[name].append(ln.upper())
    return {k: "".join(v) for k, v in seqs.items()}


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as fh:
        fh.write(text)


def write_gz(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode())
    with open(path, "wb") as fh:
        fh.write(buf.getvalue())


def tsv(header, rows):
    return TAB.join(header) + NL + "".join(TAB.join(str(v) for v in r) + NL for r in rows)


def fmt(x, nd=6):
    return f"{x:.{nd}f}".rstrip("0").rstrip(".") if isinstance(x, float) else str(x)


def run(cmd):
    subprocess.run(cmd, check=True)


# ---------------------------------------------------------------------------------------------------------------- truth
def build_truth(ref, rng):
    seq = ref[CHROM]
    sites = []
    for i, pos in enumerate(SITE_POS):
        rb = seq[pos - 1]
        if rb not in "ACGT":
            sys.exit(f"site {i} at {pos}: reference base {rb}")
        alt = "ACGT"[("ACGT".index(rb) + 1) % 4]
        cls = "own" if i in OWN else "weak" if i in WEAK else "ronly" if i in RONLY else "none"
        if cls == "own":
            kA, kB = (max(1, sum(rng.random() < 0.5 for _ in range(6))) for _ in range(2))
        elif cls == "weak":
            kA, kB = 1, 0
        else:
            kA, kB = 0, 0
        donor_alt = cls in ("own", "weak")
        ref_alt = alt
        if i == MULTI:
            ref_alt = "ACGT"[("ACGT".index(rb) + 2) % 4]
        ref_tier = "A" if (i in SHARED or i == MULTI or cls in ("weak", "ronly")) else ("ref" if i in REF_DONOR_TIER_REF else "")
        sites.append(dict(i=i, chrom=CHROM, pos=pos, ref=rb, alt=alt, cls=cls, kA=kA, kB=kB, donor_alt=donor_alt,
                          ref_donor_alt=ref_alt, ref_donor_tier=ref_tier))
    return sites


def x_at(line, pos):
    for s, e, x in SEGMENTS[line]:
        if s <= pos <= e:
            return x
    return 0


def alt_prob(sample, role, site):
    """P(a fragment of this sample carries the site's ALT allele)."""
    if role == "bc1_sample":
        return (site["kA"] if sample == "BC1_A" else site["kB"]) / 12.0
    if role == "line":
        return x_at(sample, site["pos"]) / 2.0 if site["donor_alt"] else 0.0
    return 0.0


# ---------------------------------------------------------------------------------------------------------------- reads
def mutate(base, rng):
    return rng.choice([b for b in "ACGT" if b != base])


def simulate(sample, role, npairs, artefact, ref, sites, rng):
    """SAM records (without header) and per-site [(alt read?, masked cycle?), ...] of one sample."""
    seq = ref[CHROM]
    lo, hi = REGION[1] - 1, REGION[2]
    c1, c2, rate = artefact
    recs, obs = [], {s["i"]: [] for s in sites}
    site_at = {s["pos"] - 1: s for s in sites}
    for n in range(npairs):
        flen = rng.randint(250, 350)
        start = rng.randint(lo, hi - flen)
        frag_alt = {s["i"]: rng.random() < alt_prob(sample, role, s) for s in sites if start <= s["pos"] - 1 < start + flen}
        r1_forward = rng.random() < 0.5
        left, right = start, start + flen - READ_LEN
        mates = [("R1", left, False), ("R2", right, True)] if r1_forward else [("R1", right, True), ("R2", left, False)]
        name = f"{sample}:{n:05d}"
        for mate, rpos, rev in mates:
            bases = list(seq[rpos:rpos + READ_LEN])
            for off in range(READ_LEN):
                g = rpos + off
                if g in site_at and frag_alt.get(site_at[g]["i"]):
                    bases[off] = site_at[g]["alt"]
                if rng.random() < BASE_ERR:
                    bases[off] = mutate(bases[off], rng)
            ncyc = c1 if mate == "R1" else c2
            for cyc in range(ncyc):  # 5' cycles in read orientation: the end of SEQ for a reverse-strand read
                off = READ_LEN - 1 - cyc if rev else cyc
                if rng.random() < rate:
                    bases[off] = mutate(bases[off], rng)
            for off in range(READ_LEN):
                g = rpos + off
                if g in site_at:
                    cyc = READ_LEN - 1 - off if rev else off
                    obs[site_at[g]["i"]].append([name, mate, rpos, off, bases[off] == site_at[g]["alt"], cyc < ncyc])
            flag = 1 | 2 | (64 if mate == "R1" else 128) | (16 if rev else 32)
            mpos = right if rpos == left else left
            tlen = flen if rpos == left else -flen
            recs.append([name, flag, CHROM, rpos + 1, 60, f"{READ_LEN}M", "=", mpos + 1, tlen, "".join(bases),
                         "I" * READ_LEN, f"RG:Z:{sample}", f"MC:Z:{READ_LEN}M"])
    return recs, obs


def force_b1b_read(recs, obs, sites):
    """LINE_3: one ALT read at site 15 outside the masked cycles (review #1b fixture)."""
    s = sites[B1B_SITE]
    for name, mate, rpos, off, _is_alt, masked in obs[B1B_SITE]:
        if not masked:
            for r in recs:
                if r[0] == name and r[3] == rpos + 1:
                    b = list(r[9])
                    b[off] = s["alt"]
                    r[9] = "".join(b)
                    break
            for o in obs[B1B_SITE]:
                o[4] = o[4] or (o[0] == name and o[2] == rpos)
            return name
    sys.exit("LINE_3 has no unmasked read at site 15: raise its read pairs")


def coverage(recs, lengths):
    cov = {c: bytearray(n) for c, n in lengths.items()}
    bases = 0
    for r in recs:
        c, p = r[2], r[3] - 1
        arr = cov[c]
        for g in range(p, min(p + READ_LEN, len(arr))):
            if arr[g] < 255:
                arr[g] += 1
        bases += READ_LEN
    territory = sum(lengths.values())
    covered = sum(1 for arr in cov.values() for v in arr if v >= 1)
    return bases / territory, covered / territory, territory


# ---------------------------------------------------------------------------------------------------------------- files
def write_reference(out, samtools):
    src = read_fasta(SRC_FASTA)
    ref = {"chr10": src["chrA"], "chr9": src["chrB"]}
    lines = []
    for name in ("chr10", "chr9"):
        s = ref[name]
        lines.append(f">{name}")
        lines += [s[i:i + 60] for i in range(0, len(s), 60)]
    path = os.path.join(out, "ref", "tiny10.fa")
    write_text(path, NL.join(lines) + NL)
    run([samtools, "faidx", path])
    return path, ref


def sam_header(sample, role, lengths, ref):
    hdr = ["@HD\tVN:1.6\tSO:unsorted"]
    for c in ("chr10", "chr9"):
        md5 = hashlib.md5(ref[c].encode()).hexdigest()
        hdr.append(f"@SQ\tSN:{c}\tLN:{lengths[c]}\tM5:{md5}\tUR:tiny10.fa")
    lib = {"bc1_sample": "BC1FIX", "line": "BATCH1FIX", "b73_control": "B73FIX"}[role]
    hdr.append(f"@RG\tID:{sample}\tSM:{sample}\tLB:{lib}\tPL:ILLUMINA")
    hdr.append("@CO\tzealgt genotype test fixture (tests/fixtures/genotype/make_fixtures.py); synthetic reads")
    return NL.join(hdr) + NL


def write_cram(out, samtools, fasta, sample, header, recs):
    d = os.path.join(out, "cram_store", "cram_import")
    os.makedirs(d, exist_ok=True)
    cram = os.path.join(d, f"{sample}.cram")
    with tempfile.TemporaryDirectory() as tmp:
        sam = os.path.join(tmp, f"{sample}.sam")
        with open(sam, "w") as fh:
            fh.write(header)
            for r in recs:
                fh.write(TAB.join(str(v) for v in r) + NL)
        sorted_cram = os.path.join(tmp, f"{sample}.sorted.cram")
        run([samtools, "sort", "--no-PG", "-T", os.path.join(tmp, "srt"), "-O", "cram", "--reference", fasta,
             "-o", sorted_cram, sam])
        # htslib writes the reference's absolute path into @SQ UR; put the relative name back so no checkout path is
        # tracked and the bytes do not depend on where the fixtures were made (readers pass --reference anyway)
        hdr = subprocess.run([samtools, "view", "-H", "--no-PG", sorted_cram], capture_output=True, text=True, check=True).stdout
        hdr = NL.join(TAB.join("UR:tiny10.fa" if f.startswith("UR:") else f for f in ln.split(TAB))
                      for ln in hdr.rstrip(NL).split(NL)) + NL
        hdr_path = os.path.join(tmp, "header.sam")
        write_text(hdr_path, hdr)
        with open(cram, "wb") as fh:
            subprocess.run([samtools, "reheader", "--no-PG", hdr_path, sorted_cram], stdout=fh, check=True)
    run([samtools, "index", cram])
    return cram


def write_metrics(out, sample, mean_cov, pct1, territory):
    text = (f"## htsjdk.samtools.metrics.StringHeader{NL}# CollectWgsMetrics INPUT={sample}.cram (fixture){NL}"
            f"## htsjdk.samtools.metrics.StringHeader{NL}# Started on: fixture{NL}{NL}"
            f"## METRICS CLASS\tpicard.analysis.WgsMetrics{NL}"
            f"GENOME_TERRITORY\tMEAN_COVERAGE\tSD_COVERAGE\tMEDIAN_COVERAGE\tPCT_1X\tPCT_5X{NL}"
            f"{territory}\t{mean_cov:.6f}\t0\t0\t{pct1:.6f}\t0{NL}{NL}"
            f"## HISTOGRAM\tjava.lang.Integer{NL}coverage\thigh_quality_coverage_count{NL}0\t0{NL}")
    write_text(os.path.join(out, "cram_store", "cram_import", f"{sample}.CollectWgsMetrics.coverage_metrics"), text)


def write_provenance(out, sample, role, source, cram):
    rec = {
        "schema": "zealgt.provenance/1", "sample": sample, "library": "FIXTURE", "source": source, "role": role,
        "donor": DONOR if role != "b73_control" else "", "store_dir": "tests/fixtures/genotype/cram_store/cram_import",
        "markdup": MARKDUP, "mapq_filter": "none (applied by the genotype workflow at read time)",
        "reference": "tests/fixtures/genotype/ref/tiny10.fa", "code_version": "fixture", "pipeline": "make_fixtures.py",
        "entry": "markdup_import", "run_id": "fixture", "run_name": "fixture", "session_id": "fixture", "profile": "fixture",
        "origin": {"kind": "import", "path": f"synthetic:{sample}", "made_by": "tests/fixtures/genotype/make_fixtures.py",
                   "note": "synthetic test reads", "input_filters": "none (synthetic, MAPQ 60, no duplicates)"},
        "read_group": f"@RG\\tID:{sample}\\tSM:{sample}\\tLB:FIXTURE\\tPL:ILLUMINA",
        "cram_file": os.path.basename(cram), "cram_bytes": os.path.getsize(cram),
        "tool_versions_yml": {}, "record_written_utc": "2026-09-29T00:00:00Z",
    }
    write_text(os.path.join(out, "cram_store", "cram_import", f"{sample}.provenance.json"),
               json.dumps(rec, indent=2, sort_keys=True) + NL)


def write_sheet(out):
    rows = [["sample_id", "role", "donor", "taxon", "source", "store_dir", "mask_r1", "mask_r2", "include", "mask_source"]]
    for s, role, source, (m1, m2), _n, _a in SAMPLES:
        donor, taxon = ("", "") if role == "b73_control" else (DONOR, "mexicana")
        why = {"bc1": "fixture: BC1 2/2 (design Decision 6)", "bc2s3_batch1": "fixture: batch-1 12/0 (design Decision 6)",
               "b73_control": "fixture: no artefact"}[source]
        rows.append([s, role, donor, taxon, source, "cram_import", m1, m2, "TRUE", why])
    s, role, source, (m1, m2) = EXCLUDED
    rows.append([s, role, DONOR, "mexicana", source, "cram_import", m1, m2, "FALSE", "fixture: excluded row, no files"])
    buf = io.StringIO()
    csv.writer(buf, lineterminator=NL).writerows(rows)
    write_text(os.path.join(out, "genotype_samples_test.csv"), buf.getvalue())


def write_small_inputs(out, sites):
    write_text(os.path.join(out, "lowcopy.bed"), "".join(f"{c}\t{s}\t{e}{NL}" for c, s, e in BED))
    write_text(os.path.join(out, "panel.tsv"),
               "".join(f"{sites[i]['chrom']}\t{sites[i]['pos']}\t{sites[i]['ref']}\t{sites[i]['alt']}{NL}" for i in PANEL))
    rows = []
    for b in range(31):
        c = round(b * 0.05, 2)
        w = 6 if b == 0 else int(round(100 * math.exp(-0.5 * ((c - 1.0) / 0.25) ** 2))) + 1
        rows.append([f"{c:.2f}", w])
    write_text(os.path.join(out, "priors", "mexicana.prior.tsv"), tsv(["c", "weight"], rows))


# ---------------------------------------------------------------------------------------------------------------- step 4
STEP4_COLS = ["chrom", "pos", "ref", "alt", "n", "a", "n_pools", "n_pools_alt", "eps", "n0", "a0", "self_in_zero", "LLR",
              "logodds", "posterior", "tier", "flags", "pool_counts"]


def binom_logpmf(a, n, p):
    p = min(max(p, 1e-12), 1 - 1e-12)
    return math.lgamma(n + 1) - math.lgamma(a + 1) - math.lgamma(n - a + 1) + a * math.log(p) + (n - a) * math.log(1 - p)


def pooled_llr(pools, eps):
    """LLR of 'donor carries' (k ~ Bin(6, 1/2) plants per pool, ALT fraction k/12) vs 'no carrier' (error eps)."""
    w = [math.comb(6, k) / 64.0 for k in range(7)]
    llr = 0.0
    for a, n in pools:
        h1 = math.log(sum(wk * math.exp(binom_logpmf(a, n, k / 12.0 * (1 - eps) + (1 - k / 12.0) * eps)) for k, wk in enumerate(w)))
        llr += h1 - binom_logpmf(a, n, eps)
    return llr


def tier_of(llr, n, n_pools_alt):
    if llr >= 6.9:
        return "A" if n_pools_alt >= 2 else "B"
    if llr >= 4.6:
        return "B"
    if llr >= 2.2:
        return "C"
    if llr <= -4 and n >= 12:
        return "ref"
    return "."


def counts(obs, i, masked_ok=True):
    o = obs[i]
    use = [x for x in o if masked_ok or not x[5]]
    return sum(1 for x in use if x[4]), len(use)


def step4_rows(sites, obs_by_sample):
    eps = 0.005
    rows = []
    for s in sites:
        i = s["i"]
        pools = [counts(obs_by_sample[p], i, masked_ok=False) for p in ("BC1_A", "BC1_B")]
        a, n = sum(p[0] for p in pools), sum(p[1] for p in pools)
        if n == 0:
            continue
        a0, n0 = counts(obs_by_sample["B73_CTL"], i, masked_ok=False)
        llr = pooled_llr(pools, eps)
        npa = sum(1 for p in pools if p[0] > 0)
        tier = tier_of(llr, n, npa)
        if tier == ".":
            continue
        post = 1.0 / (1.0 + math.exp(-llr)) if llr > -700 else 0.0
        pc = ";".join(f"{name}:{pa}/{pn}" for name, (pa, pn) in zip(("BC1_A", "BC1_B"), pools))
        rows.append([s["chrom"], s["pos"], s["ref"], s["alt"], n, a, sum(1 for p in pools if p[1] > 0), npa, eps, n0, a0,
                     0, f"{llr:.6f}", f"{llr:.6f}", f"{post:.4f}", tier, ".", pc])
    return rows


def ref_donor_rows(sites):
    rows = []
    for s in sites:
        t = s["ref_donor_tier"]
        if not t:
            continue
        if t == "A":
            rows.append([s["chrom"], s["pos"], s["ref"], s["ref_donor_alt"], 40, 9, 2, 2, 0.005, 30, 0, 0, "21.5", "21.5",
                         "1.0000", "A", ".", "S_REF_A:5/20;S_REF_B:4/20"])
        else:
            rows.append([s["chrom"], s["pos"], s["ref"], s["alt"], 36, 0, 2, 0, 0.005, 30, 0, 0, "-7.2", "-7.2", "0.0007",
                         "ref", ".", "S_REF_A:0/18;S_REF_B:0/18"])
    # outside the region (the table of a zealbc1 donor covers the whole chromosome; MARKER_UNION clips it)
    rows.append(["chr10", 17500, "A", "G", 40, 10, 2, 2, 0.005, 30, 0, 0, "22.0", "22.0", "1.0000", "A", ".", "S_REF_A:5/20;S_REF_B:5/20"])
    rows.append(["chr9", 2000, "C", "T", 40, 10, 2, 2, 0.005, 30, 0, 0, "22.0", "22.0", "1.0000", "A", ".", "S_REF_A:5/20;S_REF_B:5/20"])
    return rows


# ---------------------------------------------------------------------------------------------------------------- seed store
SEED_LINE_FLOOR = 12  # covered own tier-A markers a seeded line needs in LINE_MARKER_QC (see write_seed)


def write_seed(out, sites, obs_by_sample, cov):
    root = os.path.join(out, "store_seed", "genotype", KEY)
    # sample_qc (SAMPLE_QC_TABLE columns)
    hdr = ["sample", "role", "donor", "pass", "reasons", "notes", "mean_coverage", "pct_1x", "panel_qc", "panel_min_covered",
           "panel_contigs_below_floor", "kinship_own", "own_z", "closest_other_donor", "kinship_closest_other",
           "relatedness_reason", "donor_content", "donor_content_reason"]
    rows = []
    for s, role, _src, _m, _n, _a in SAMPLES:
        mc, p1 = cov[s][0], cov[s][1]
        ok = mc >= 0.05
        rows.append([s, role, DONOR if role != "b73_control" else ".", "true" if ok else "false",
                     "." if ok else "min_coverage", ".", f"{mc:.6f}", f"{p1:.6f}", "not_run", ".", ".", ".", ".", ".", ".",
                     ".", ".", "."])
    write_text(os.path.join(root, "sample_qc", "cohort.sample_qc.tsv"), tsv(hdr, rows))
    # step4 (POOLED_LIKELIHOOD_TIERS) of the run donor
    s4 = step4_rows(sites, obs_by_sample)
    base = os.path.join(root, "step4", f"{DONOR}.{LABEL}")
    write_gz(base + ".sites.tsv.gz", tsv(STEP4_COLS, s4))
    tiers = {t: sum(1 for r in s4 if r[15] == t) for t in ("A", "B", "C", "ref")}
    write_text(base + ".summary.tsv", tsv(["donor", "tier_A", "tier_B", "tier_C", "tier_ref"],
                                          [[DONOR, tiers["A"], tiers["B"], tiers["C"], tiers["ref"]]]))
    write_text(base + ".pool_qc.tsv", tsv(["pool", "sites_with_reads"], [["BC1_A", len(sites)], ["BC1_B", len(sites)]]))
    write_text(base + ".run_info.txt", f"fixture seed (make_fixtures.py): step-4 table of {DONOR} in {LABEL}{NL}")
    own_a = {(r[0], r[1], r[2], r[3]) for r in s4 if r[15] == "A"}
    # ancestry: LINE_MARKER_QC line_qc for the lines that pass sample QC (2b), RTIGER segments for those that also pass the
    # seed marker floor. SEED_LINE_FLOOR = 12 covered own tier-A markers excludes LINE_2 (11 covered) at stage 4, so the
    # pipeline tests see one line dropped at 2b (LINE_LOW) and another at LINE_MARKER_QC (LINE_2), both absent downstream.
    lines = [s for s, role, *_ in SAMPLES if role == "line" and cov[s][0] >= 0.05]
    covered = {ln: sum(1 for s in sites if (s["chrom"], s["pos"], s["ref"], s["alt"]) in own_a and counts(obs_by_sample[ln], s["i"])[1] > 0)
               for ln in lines}
    passing = [ln for ln in lines if covered[ln] >= SEED_LINE_FLOOR]
    seg = [["source", "donor", "name", "chr", "start_bp", "end_bp", "state"]]
    for ln in passing:
        seg += [["RTIGER_poolseq", DONOR, ln, 10, a, b, x] for a, b, x in SEGMENTS[ln]]
    buf = io.StringIO()
    csv.writer(buf, lineterminator=NL).writerows(seg)
    abase = os.path.join(root, "ancestry", f"{DONOR}.{LABEL}")
    write_text(abase + ".segments.csv", buf.getvalue())
    qc = []
    for ln in lines:
        cvd = sum(1 for s in sites if (s["chrom"], s["pos"], s["ref"], s["alt"]) in own_a and counts(obs_by_sample[ln], s["i"])[1] > 0)
        rd = sum(counts(obs_by_sample[ln], s["i"])[1] for s in sites if (s["chrom"], s["pos"], s["ref"], s["alt"]) in own_a)
        ok = cvd >= SEED_LINE_FLOOR
        qc.append([ln, CHROM, len(own_a), len(own_a), cvd, rd, f"{rd / max(1, len(own_a)):.3f}", SEED_LINE_FLOOR,
                   "true" if ok else "false", "true" if ok else "false", "." if ok else "below_marker_floor"])
    write_text(abase + ".line_qc.tsv", tsv(["sample", "contig", "markers", "markers_kept", "covered", "reads", "mean_depth",
                                            "floor", "contig_pass", "line_pass", "reason"], qc))
    # own tier-A sites as RTIGER_MARKERS stores them (no header), read by reporting (READ_POSITION_QC)
    write_text(abase + ".tierA_sites.tsv", "".join(TAB.join(str(v) for v in k) + NL for k in sorted(own_a, key=lambda k: k[1])))
    # union (MARKER_UNION)
    ref_a = {(s["chrom"], s["pos"], s["ref"], s["ref_donor_alt"]) for s in sites if s["ref_donor_tier"] == "A"}
    ref_ref = {(s["chrom"], s["pos"], s["ref"], s["alt"]) for s in sites if s["ref_donor_tier"] == "ref"}
    keys = sorted(own_a | ref_a, key=lambda k: (k[1], k[3]))
    alts_at = {}
    for k in keys:
        alts_at.setdefault(k[1], set()).add(k[3])
    urows, usites = [], []
    for k in keys:
        carriers = [(d, kind) for d, kind, have in ((DONOR, "run", k in own_a), (REF_DONOR, "reference", k in ref_a)) if have]
        multi = 1 if len(alts_at[k[1]]) > 1 else 0
        urows.append([k[0], k[1], k[2], k[3], len(carriers), ",".join(d for d, _ in carriers), multi,
                      ",".join(kind for _, kind in carriers), REF_DONOR if k in ref_ref else "."])
        if not multi:
            usites.append(k)
    ubase = os.path.join(root, "union", f"{DONOR_SET}.{LABEL}")
    write_gz(ubase + ".tsv.gz", tsv(["chrom", "pos", "ref", "alt", "n_donors", "donors", "multiallelic", "donor_kind",
                                     "ref_donors"], urows))
    write_text(ubase + ".union_sites.tsv", "".join(TAB.join(str(v) for v in k) + NL for k in usites))
    n_gaps = sum(1 for k in usites if k not in own_a)
    write_text(ubase + ".per_donor.tsv", tsv(["donor", "donor_kind", "table", "table_sha256", "tierA", "shared", "private",
                                              "union_alleles", "n_gaps", "multiallelic_own"],
                                             [[DONOR, "run", f"{DONOR}.{LABEL}.sites.tsv.gz", "fixture", len(own_a),
                                               len(own_a & ref_a), len(own_a - ref_a), len(keys), n_gaps, 1],
                                              [REF_DONOR, "reference", f"{REF_DONOR}.sites.tsv.gz", "fixture", len(ref_a),
                                               len(own_a & ref_a), len(ref_a - own_a), len(keys), len([k for k in usites if k not in ref_a]), 1]]))
    # donor_alleles (DONOR_FOUNDER): own ALT; weak gaps ALT (step1/step2); ronly REF or missing; multiallelic NA
    by_key = {(s["chrom"], s["pos"], s["ref"], s["alt"]): s for s in sites}
    da = []
    for k in keys:
        if k not in by_key:
            continue  # the reference donor's other ALT at the multiallelic site: the run donor's row stands for the position
        s = by_key[k]
        if len(alts_at[k[1]]) > 1:
            da.append([*k, "NA", "multiallelic", ".", "."])
        elif k in own_a:
            da.append([*k, "ALT", "own", ".", "1"])
        elif s["cls"] == "weak":
            step = "step1_alt" if s["i"] == 12 else "step2_alt"
            da.append([*k, "ALT", step, "9.5" if step == "step1_alt" else "7.4", "0.9999"])
        elif s["i"] in (14, 16):
            da.append([*k, "REF", "step1_ref", "-8.1", "0.0003"])
        else:
            da.append([*k, "NA", "missing", "-1.2", "0.23"])
    dbase = os.path.join(root, "donor_alleles", DONOR_SET, f"{DONOR}.{LABEL}")
    write_gz(dbase + ".tsv.gz", tsv(["chrom", "pos", "ref", "alt", "D", "call_step", "logodds", "p_alt"], da))
    steps = {}
    for r in da:
        steps[r[5]] = steps.get(r[5], 0) + 1
    write_text(dbase + ".summary.tsv", tsv(sorted(steps), [[steps[k] for k in sorted(steps)]]))
    # genotypes (RASTERIZE): long + wide
    long_rows, gt_by = [], {}
    for r in da:
        if r[5] == "multiallelic":
            continue
        for ln in lines:
            if ln not in passing:  # excluded by LINE_MARKER_QC: NA everywhere (RASTERIZE)
                long_rows.append([ln, r[0], r[1], r[2], r[3], "NA", r[4], "NA", "NA"])
                gt_by[(r[1], ln)] = "NA"
                continue
            x = x_at(ln, r[1])
            D = r[4]
            gt = x if D == "ALT" else 0 if D == "REF" else ("NA" if x > 0 else 0)
            p = 1.0 if r[7] == "1" else (float(r[7]) if r[7] != "." else 0.0)
            long_rows.append([ln, r[0], r[1], r[2], r[3], x, D, gt, f"{x * p:.4f}"])
            gt_by[(r[1], ln)] = gt
    gbase = os.path.join(root, "genotypes", DONOR_SET, f"{DONOR}.{LABEL}")
    write_gz(gbase + ".genotypes.tsv.gz", tsv(["line", "chrom", "pos", "ref", "alt", "x", "D", "gt", "dosage_expected"], long_rows))
    wide = [[r[0], r[1], r[2], r[3]] + [gt_by[(r[1], ln)] for ln in lines] for r in da if r[5] != "multiallelic"]
    write_gz(gbase + ".genotypes.matrix.tsv.gz", tsv(["chrom", "pos", "ref", "alt"] + lines, wide))
    return s4, passing


def write_truth(out, sites, obs_by_sample):
    rows = []
    for s in sites:
        per = [f"{sm}:{counts(obs_by_sample[sm], s['i'])[0]}/{counts(obs_by_sample[sm], s['i'])[1]}" for sm, *_ in SAMPLES]
        rows.append([s["i"], s["chrom"], s["pos"], s["ref"], s["alt"], s["cls"], int(s["donor_alt"]), s["kA"], s["kB"],
                     s["ref_donor_alt"], s["ref_donor_tier"] or ".", int(s["i"] in PANEL), ";".join(per)])
    write_text(os.path.join(out, "truth", "sites.tsv"),
               tsv(["site", "chrom", "pos", "ref", "alt", "class", "donor_alt", "k_BC1_A", "k_BC1_B", "ref_donor_alt",
                    "ref_donor_tier", "in_panel", "alt_reads_per_sample(all cycles)"], rows))
    write_text(os.path.join(out, "truth", "segments.tsv"),
               tsv(["line", "chrom", "start", "end", "x"], [[ln, CHROM, a, b, x] for ln, segs in SEGMENTS.items() for a, b, x in segs]))


def write_manifest(out, samtools):
    ver = subprocess.run([samtools, "--version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    rows = []
    for dp, _dn, fn in os.walk(out):
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, out)
            if rel in ("MANIFEST.tsv", "make_fixtures.py") or "__pycache__" in rel:
                continue
            with open(p, "rb") as fh:
                data = fh.read()
            rows.append([rel, len(data), hashlib.sha256(data).hexdigest()])
    rows.sort()
    write_text(os.path.join(out, "MANIFEST.tsv"),
               f"# written by make_fixtures.py (seed {SEED}) with {ver}, python {sys.version.split()[0]}{NL}" + tsv(["path", "bytes", "sha256"], rows))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--outdir", default=HERE)
    ap.add_argument("--samtools", default=shutil.which("samtools") or "samtools")
    a = ap.parse_args()
    out = os.path.abspath(a.outdir)
    # Files are overwritten in place, never deleted: a file this script no longer writes stays and shows up in MANIFEST.tsv.
    rng = random.Random(SEED)
    fasta, ref = write_reference(out, a.samtools)
    lengths = {c: len(s) for c, s in ref.items()}
    sites = build_truth(ref, rng)
    obs_by_sample, cov = {}, {}
    for s, role, source, _m, npairs, art in SAMPLES:
        recs, obs = simulate(s, role, npairs, art, ref, sites, rng)
        if s == "LINE_3":
            force_b1b_read(recs, obs, sites)
        obs_by_sample[s] = obs
        cram = write_cram(out, a.samtools, fasta, s, sam_header(s, role, lengths, ref), recs)
        cov[s] = coverage(recs, lengths)
        write_metrics(out, s, *cov[s])
        write_provenance(out, s, role, source, cram)
    write_sheet(out)
    write_small_inputs(out, sites)
    write_gz(os.path.join(out, "reference", f"{REF_DONOR}.sites.tsv.gz"), tsv(STEP4_COLS, ref_donor_rows(sites)))
    s4, lines = write_seed(out, sites, obs_by_sample, cov)
    write_truth(out, sites, obs_by_sample)
    write_manifest(out, a.samtools)
    print(f"fixtures in {out}: {len(SAMPLES)} CRAMs, {len(sites)} sites, step-4 seed {len(s4)} rows "
          f"(tier A {sum(1 for r in s4 if r[15] == 'A')}), lines passing QC {lines}")


if __name__ == "__main__":
    main()
