#!/usr/bin/env python3
"""Minimum-coverage rule of stage 2b (MIN_COVERAGE, PLAN §3 row 2b; decided 2026-09-27).

Nextflow module template (modules/local/min_coverage/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline are
chr(9) / chr(10).

Reads, per sample, the Picard CollectWgsMetrics file metrics/<sample>.CollectWgsMetrics.coverage_metrics (the first
"## METRICS CLASS" block: a header line and one value line) and writes <prefix>.min_coverage.tsv:
  sample  mean_coverage  pct_1x  min_coverage  pass  reason
pass = mean_coverage >= min_coverage. reason: "." (pass), "below_min_coverage", "no_metrics_file", "no_mean_coverage".
The metrics file of a sample is found by name (<sample>. prefix; sample ids hold no dots, assets/schema_genotype.json).
Standard library only.
"""
import json
import os
import platform
import sys

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
METRICS = "${metrics}".split()
SAMPLE_IDS = json.loads('''${groovy.json.JsonOutput.toJson(sample_ids)}''')
MIN_COVERAGE = float("${min_coverage}")


def read_wgs_metrics(path):
    """MEAN_COVERAGE and PCT_1X (None when absent) from a Picard CollectWgsMetrics file."""
    with open(path) as fh:
        lines = [ln.rstrip(NL) for ln in fh]
    for i, ln in enumerate(lines):
        if ln.startswith("## METRICS CLASS"):
            if i + 2 >= len(lines):
                break
            hdr = lines[i + 1].split(TAB)
            val = lines[i + 2].split(TAB)
            row = dict(zip(hdr, val))
            out = {}
            for key in ("MEAN_COVERAGE", "PCT_1X"):
                try:
                    out[key] = float(row[key])
                except (KeyError, ValueError):
                    out[key] = None
            return out
    return {"MEAN_COVERAGE": None, "PCT_1X": None}


def main():
    if len(set(SAMPLE_IDS)) != len(SAMPLE_IDS):
        sys.exit("min_coverage: duplicate sample ids in the input")
    by_name = {os.path.basename(p): p for p in METRICS}
    rows = []
    for s in SAMPLE_IDS:
        hits = [p for n, p in by_name.items() if n.startswith(s + ".")]
        if len(hits) > 1:
            sys.exit(f"min_coverage: {len(hits)} metrics files match sample {s}: {sorted(hits)}")
        if not hits:
            rows.append([s, "NA", "NA", MIN_COVERAGE, "false", "no_metrics_file"])
            continue
        m = read_wgs_metrics(hits[0])
        mc, p1 = m["MEAN_COVERAGE"], m["PCT_1X"]
        p1s = "NA" if p1 is None else f"{p1:.6g}"
        if mc is None:
            rows.append([s, "NA", p1s, MIN_COVERAGE, "false", "no_mean_coverage"])
        elif mc < MIN_COVERAGE:
            rows.append([s, f"{mc:.6g}", p1s, MIN_COVERAGE, "false", "below_min_coverage"])
        else:
            rows.append([s, f"{mc:.6g}", p1s, MIN_COVERAGE, "true", "."])
    with open(f"{PREFIX}.min_coverage.tsv", "w") as out:
        out.write(TAB.join(["sample", "mean_coverage", "pct_1x", "min_coverage", "pass", "reason"]) + NL)
        for r in rows:
            out.write(TAB.join(str(v) for v in r) + NL)
    n_fail = sum(1 for r in rows if r[4] == "false")
    print(f"min_coverage {PREFIX}: {len(rows)} samples, {n_fail} fail (min_coverage {MIN_COVERAGE})")
    with open(f"{PREFIX}.min_coverage.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
