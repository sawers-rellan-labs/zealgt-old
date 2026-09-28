#!/usr/bin/env python3
"""Per-library demultiplexing QC from the cutadapt JSON report and the demuxed FASTQs (DEMUX_QC, PLAN §3 row 1, §4 #4).

Writes, for one library:
  <library>.tsv                  one row per expected sample: barcodes, assigned read pairs, share of input pairs
  <library>.summary.tsv          one row: input pairs, assigned, unassigned, assignment rate, samples with 0 pairs
  <library>.read_start.tsv       per sample x read (R1/R2) x position 1..N: base composition of the first --check-reads
                                 reads (a check that no barcode / skip bases remain at the read start) plus the share of those
                                 reads containing the TruSeq read-through adapter of that read
Assigned pairs come from cutadapt's per-adapter total_matches (with --pair-adapters a pair counts only when both reads match;
checked on toy data 2026-09-28). Standard library only.
"""
import argparse
import csv
import gzip
import json
import sys
from collections import Counter

ADAPTERS = {  # TruSeq read-through (Illumina adapter sequences; Twist libraries are TruSeq-compatible, see Phase B handover)
    "R1": "AGATCGGAAGAGCACACGTCTGAACTCCAGTCAC",
    "R2": "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT",
}


def read_barcodes(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def fastq_head(path, n):
    """First n sequences of a (possibly empty) gzipped FASTQ."""
    seqs = []
    with gzip.open(path, "rt") as fh:
        for i, line in enumerate(fh):
            if i % 4 == 1:
                seqs.append(line.rstrip("\n"))
                if len(seqs) >= n:
                    break
    return seqs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", required=True)
    ap.add_argument("--json", required=True, help="cutadapt --json report of the library")
    ap.add_argument("--barcodes", required=True, help="TSV sample_id, barcode_r1, barcode_r2")
    ap.add_argument("--reads-dir", required=True, help="directory with <sample>_R1.fastq.gz / _R2.fastq.gz")
    ap.add_argument("--check-reads", type=int, default=100000)
    ap.add_argument("--positions", type=int, default=10)
    ap.add_argument("--subsample", type=int, default=0)
    a = ap.parse_args()

    rep = json.load(open(a.json))
    counts = rep.get("read_counts") or {}
    n_input = counts.get("input") or 0
    matches = {ad["name"]: ad.get("total_matches", 0) for ad in (rep.get("adapters_read1") or [])}
    samples = read_barcodes(a.barcodes)

    unknown = sorted(set(matches) - {s["sample_id"] for s in samples})
    if unknown:
        sys.exit(f"demux_qc: adapters in the cutadapt report that are not in the barcode table: {unknown}")

    lib = a.library
    assigned_total = 0
    zero = []
    with open(f"{lib}.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter="\t", lineterminator="\n")
        w.writerow(["library", "sample_id", "barcode_r1", "barcode_r2", "read_pairs", "share_of_input", "subsample"])
        for s in samples:
            n = matches.get(s["sample_id"], 0)
            assigned_total += n
            if n == 0:
                zero.append(s["sample_id"])
            w.writerow([lib, s["sample_id"], s["barcode_r1"], s["barcode_r2"], n,
                        f"{n / n_input:.6f}" if n_input else "NA", a.subsample])

    with open(f"{lib}.summary.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter="\t", lineterminator="\n")
        w.writerow(["library", "cutadapt_version", "input_pairs", "assigned_pairs", "unassigned_pairs", "assignment_rate",
                    "n_samples", "samples_zero_pairs", "subsample"])
        w.writerow([lib, rep.get("cutadapt_version", "NA"), n_input, assigned_total, n_input - assigned_total,
                    f"{assigned_total / n_input:.6f}" if n_input else "NA", len(samples), ",".join(zero) or "-",
                    a.subsample])

    with open(f"{lib}.read_start.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter="\t", lineterminator="\n")
        w.writerow(["library", "sample_id", "read", "reads_checked", "position", "A", "C", "G", "T", "N",
                    "adapter_readthrough_share"])
        for s in samples:
            for r in ("R1", "R2"):
                seqs = fastq_head(f"{a.reads_dir}/{s['sample_id']}_{r}.fastq.gz", a.check_reads)
                n = len(seqs)
                ad = sum(1 for q in seqs if ADAPTERS[r] in q)
                share = f"{ad / n:.6f}" if n else "NA"
                for p in range(a.positions):
                    c = Counter(q[p] for q in seqs if len(q) > p)
                    tot = sum(c.values())
                    fr = [f"{c.get(b, 0) / tot:.4f}" if tot else "NA" for b in "ACGTN"]
                    w.writerow([lib, s["sample_id"], r, n, p + 1, *fr, share])


if __name__ == "__main__":
    main()
