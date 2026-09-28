#!/usr/bin/env python3
"""Per-library demultiplexing QC from the cutadapt JSON report and the demuxed FASTQs (DEMUX_QC, PLAN §3 row 1, §4 #4).

Nextflow module template (modules/local/demux_qc/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders (the template engine
would read them); tab and newline are chr(9) / chr(10).

Writes, for one library:
  <library>.tsv                  one row per expected sample: barcodes, assigned read pairs, share of input pairs
  <library>.summary.tsv          one row: input pairs, assigned, unassigned, assignment rate, samples with 0 pairs
  <library>.read_start.tsv       per sample x read (R1/R2) x position 1..N: base composition of the first --check-reads
                                 reads (a check that no barcode / skip bases remain at the read start) plus the share of those
                                 reads containing the TruSeq read-through adapter of that read
  <library>.cutadapt.json / .log the cutadapt reports, kept next to the tables
  <library>.demux_qc.versions.yml
Assigned pairs come from cutadapt's per-adapter total_matches (with --pair-adapters a pair counts only when both reads match;
checked on toy data 2026-09-28). Options (ext.args): --check-reads N (default 100000), --positions N (default 10).
Standard library only.
"""
import argparse
import csv
import gzip
import json
import platform
import shlex
import shutil
import sys
from collections import Counter

TAB = chr(9)
NL = chr(10)
ADAPTERS = {  # TruSeq read-through (Illumina adapter sequences; Twist libraries are TruSeq-compatible, see Phase B handover)
    "R1": "AGATCGGAAGAGCACACGTCTGAACTCCAGTCAC",
    "R2": "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT",
}

LIBRARY = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
CUTADAPT_JSON = "${json}"
CUTADAPT_LOG = "${report}"
READS_DIR = "reads"
SUBSAMPLE = int("${subsample}")
BARCODES = json.loads('''${groovy.json.JsonOutput.toJson(barcodes)}''')  # [[sample_id, barcode_r1, barcode_r2], ...]
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')


def fastq_head(path, n):
    """First n sequences of a (possibly empty) gzipped FASTQ."""
    seqs = []
    with gzip.open(path, "rt") as fh:
        for i, line in enumerate(fh):
            if i % 4 == 1:
                seqs.append(line.rstrip(NL))
                if len(seqs) >= n:
                    break
    return seqs


def main():
    ap = argparse.ArgumentParser(description="DEMUX_QC options (task.ext.args)")
    ap.add_argument("--check-reads", type=int, default=100000)
    ap.add_argument("--positions", type=int, default=10)
    a = ap.parse_args(EXT_ARGS)

    with open(CUTADAPT_JSON) as fh:
        rep = json.load(fh)
    counts = rep.get("read_counts") or {}
    n_input = counts.get("input") or 0
    matches = {ad["name"]: ad.get("total_matches", 0) for ad in (rep.get("adapters_read1") or [])}
    samples = [{"sample_id": s, "barcode_r1": b1, "barcode_r2": b2 or "-"} for s, b1, b2 in BARCODES]

    unknown = sorted(set(matches) - {s["sample_id"] for s in samples})
    if unknown:
        sys.exit(f"demux_qc: adapters in the cutadapt report that are not in the barcode table: {unknown}")

    lib = LIBRARY
    shutil.copyfile(CUTADAPT_JSON, f"{lib}.cutadapt.json")
    shutil.copyfile(CUTADAPT_LOG, f"{lib}.cutadapt.log")
    assigned_total = 0
    zero = []
    with open(f"{lib}.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter=TAB, lineterminator=NL)
        w.writerow(["library", "sample_id", "barcode_r1", "barcode_r2", "read_pairs", "share_of_input", "subsample"])
        for s in samples:
            n = matches.get(s["sample_id"], 0)
            assigned_total += n
            if n == 0:
                zero.append(s["sample_id"])
            w.writerow([lib, s["sample_id"], s["barcode_r1"], s["barcode_r2"], n,
                        f"{n / n_input:.6f}" if n_input else "NA", SUBSAMPLE])

    with open(f"{lib}.summary.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter=TAB, lineterminator=NL)
        w.writerow(["library", "cutadapt_version", "input_pairs", "assigned_pairs", "unassigned_pairs", "assignment_rate",
                    "n_samples", "samples_zero_pairs", "subsample"])
        w.writerow([lib, rep.get("cutadapt_version", "NA"), n_input, assigned_total, n_input - assigned_total,
                    f"{assigned_total / n_input:.6f}" if n_input else "NA", len(samples), ",".join(zero) or "-",
                    SUBSAMPLE])

    with open(f"{lib}.read_start.tsv", "w", newline="") as out:
        w = csv.writer(out, delimiter=TAB, lineterminator=NL)
        w.writerow(["library", "sample_id", "read", "reads_checked", "position", "A", "C", "G", "T", "N",
                    "adapter_readthrough_share"])
        for s in samples:
            for r in ("R1", "R2"):
                seqs = fastq_head(f"{READS_DIR}/{s['sample_id']}_{r}.fastq.gz", a.check_reads)
                n = len(seqs)
                ad = sum(1 for q in seqs if ADAPTERS[r] in q)
                share = f"{ad / n:.6f}" if n else "NA"
                for p in range(a.positions):
                    c = Counter(q[p] for q in seqs if len(q) > p)
                    tot = sum(c.values())
                    fr = [f"{c.get(b, 0) / tot:.4f}" if tot else "NA" for b in "ACGTN"]
                    w.writerow([lib, s["sample_id"], r, n, p + 1, *fr, share])

    with open(f"{lib}.demux_qc.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
