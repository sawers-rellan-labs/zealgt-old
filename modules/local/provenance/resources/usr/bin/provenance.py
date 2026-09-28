#!/usr/bin/env python3
"""Per-sample provenance record for a stored CRAM (PROVENANCE, PLAN §3 "CRAM workflow stop point").

Merges the record built by the workflow (source, demux / trimming / alignment / markdup settings, reference, code version,
run) with the tool versions of the steps that made the CRAM (their versions.yml files, kept verbatim) and the CRAM's size.
The genotype workflow checks each CRAM's record against the current read-processing settings. Standard library only.
"""
import argparse
import datetime
import json
import os


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--record", required=True, help="JSON written by the workflow")
    ap.add_argument("--cram", required=True)
    ap.add_argument("--versions", nargs="*", default=[], help="versions.yml files of the steps")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rec = json.load(open(a.record))
    rec["cram_file"] = os.path.basename(a.cram)
    rec["cram_bytes"] = os.path.getsize(os.path.realpath(a.cram))
    rec["tool_versions_yml"] = {os.path.basename(v): open(v).read() for v in sorted(a.versions)}
    rec["record_written_utc"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rec["schema"] = "zealgt.provenance/1"
    with open(a.out, "x") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")


if __name__ == "__main__":
    main()
