#!/usr/bin/env python3
"""Demux registry entry for one library (REGISTRY, PLAN §0 Task 2).

Nextflow module template (modules/local/registry/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline are
chr(9) / chr(10).

A library is registered as done when its demux QC table and ALL its sample CRAMs are in the store. This checks that every
expected sample has a non-empty CRAM and index among the staged files and that the demux QC table lists exactly the expected
samples, then writes <library>.registry.tsv (one row per sample). It exits non-zero, writing nothing, if anything is missing,
so a library is never registered with a gap. read_demultiplexing refuses a registered library unless --force_demux <library>.
Standard library only.
"""
import csv
import datetime
import json
import os
import platform
import sys

TAB = chr(9)
NL = chr(10)

LIBRARY = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
DEMUX_QC = "${demux_qc}"
CRAM_DIR = "cram"
SAMPLES = json.loads('''${groovy.json.JsonOutput.toJson(samples)}''')
STORE = '''${store}'''
RUN_ID = '''${run_id ?: 'NA'}'''
CODE_VERSION = '''${code_version ?: 'NA'}'''
SUBSAMPLE = int("${subsample}")


def main():
    expected = sorted(set(SAMPLES))
    with open(DEMUX_QC, newline="") as fh:
        qc = {r["sample_id"]: r for r in csv.DictReader(fh, delimiter=TAB)}
    problems = []
    if sorted(qc) != expected:
        problems.append(f"demux QC samples {sorted(qc)} != expected {expected}")
    rows = []
    for s in expected:
        cram = os.path.join(CRAM_DIR, f"{s}.cram")
        crai = cram + ".crai"
        for f in (cram, crai):
            if not os.path.exists(f) or os.path.getsize(os.path.realpath(f)) == 0:
                problems.append(f"missing or empty {os.path.basename(f)}")
        if not problems:
            rows.append([LIBRARY, s, qc[s]["read_pairs"], os.path.getsize(os.path.realpath(cram))])
    if problems:
        sys.exit(f"registry: library {LIBRARY} NOT registered: " + "; ".join(problems))

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(f"{LIBRARY}.registry.tsv", "x", newline="") as out:
        w = csv.writer(out, delimiter=TAB, lineterminator=NL)
        w.writerow(["library", "sample_id", "demux_read_pairs", "cram_bytes", "store", "subsample", "run_id",
                    "code_version", "registered_utc"])
        for r in rows:
            w.writerow(r + [STORE, SUBSAMPLE, RUN_ID, CODE_VERSION, now])

    with open(f"{LIBRARY}.registry.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
