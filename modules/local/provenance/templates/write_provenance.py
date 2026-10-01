#!/usr/bin/env python3
"""Per-sample provenance record for a stored CRAM (PROVENANCE, PLAN §3 "CRAM workflow stop point").

Nextflow module template (modules/local/provenance/main.nf): the Groovy placeholders are filled in by Nextflow, so the task
hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; newline is chr(10).

Merges the record built by the pipeline (the `record` JSON input, base64-encoded into this script because it contains
backslashes (the escaped read-group tabs) that the template engine would read; source, demux / trimming / alignment / markdup settings, reference,
code version, run, and the tool versions of the steps run in this session) with the versions.yml files of the steps that made
the CRAM (kept verbatim) and the CRAM's size. The genotype workflow checks each CRAM's record against the current
read-processing settings. Standard library only.
"""
import base64
import datetime
import glob
import json
import os
import platform
import logging
import sys
logging.basicConfig(stream=sys.stderr, level=logging.INFO, datefmt="%Y-%m-%d %H:%M:%S",
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
LOG = logging.getLogger("provenance")

NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
CRAM = "${cram}"
RECORD_B64 = "${record.getBytes('UTF-8').encodeBase64().toString()}"


def main():
    rec = json.loads(base64.b64decode(RECORD_B64).decode("utf-8"))
    rec["cram_file"] = os.path.basename(CRAM)
    rec["cram_bytes"] = os.path.getsize(os.path.realpath(CRAM))
    versions = sorted(glob.glob("versions/*"))
    rec["tool_versions_yml"] = {os.path.basename(v): open(v).read() for v in versions}
    rec["record_written_utc"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rec["schema"] = "zealgt.provenance/1"
    with open(f"{PREFIX}.provenance.json", "x") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write(NL)
    with open(f"{PREFIX}.provenance.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
