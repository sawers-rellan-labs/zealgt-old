#!/usr/bin/env python3
"""Demux registry entry for one library (REGISTRY, PLAN §0 Task 2).

A library is registered as done when its demux QC table and ALL its sample CRAMs are in the store. This script checks that
every expected sample has a non-empty CRAM and index among the staged files and that the demux QC table lists exactly the
expected samples, then writes <library>.registry.tsv (one row per sample). It exits non-zero, writing nothing, if anything is
missing, so a library is never registered with a gap. read_demultiplexing refuses a registered library unless
--force-demux <library>. Standard library only.
"""
import argparse
import csv
import datetime
import os
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--library", required=True)
    ap.add_argument("--demux-qc", required=True)
    ap.add_argument("--cram-dir", required=True)
    ap.add_argument("--samples", required=True, nargs="+")
    ap.add_argument("--store", required=True, help="store root the CRAMs and the demux QC live in (recorded)")
    ap.add_argument("--run-id", default="NA")
    ap.add_argument("--code-version", default="NA")
    ap.add_argument("--subsample", type=int, default=0)
    a = ap.parse_args()

    expected = sorted(set(a.samples))
    with open(a.demux_qc, newline="") as fh:
        qc = {r["sample_id"]: r for r in csv.DictReader(fh, delimiter="\t")}
    problems = []
    if sorted(qc) != expected:
        problems.append(f"demux QC samples {sorted(qc)} != expected {expected}")
    rows = []
    for s in expected:
        cram = os.path.join(a.cram_dir, f"{s}.cram")
        crai = cram + ".crai"
        for f in (cram, crai):
            if not os.path.exists(f) or os.path.getsize(os.path.realpath(f)) == 0:
                problems.append(f"missing or empty {os.path.basename(f)}")
        if not problems:
            rows.append([a.library, s, qc[s]["read_pairs"], os.path.getsize(os.path.realpath(cram))])
    if problems:
        sys.exit(f"registry: library {a.library} NOT registered: " + "; ".join(problems))

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(f"{a.library}.registry.tsv", "x", newline="") as out:
        w = csv.writer(out, delimiter="\t", lineterminator="\n")
        w.writerow(["library", "sample_id", "demux_read_pairs", "cram_bytes", "store", "subsample", "run_id",
                    "code_version", "registered_utc"])
        for r in rows:
            w.writerow(r + [a.store, a.subsample, a.run_id, a.code_version, now])


if __name__ == "__main__":
    main()
