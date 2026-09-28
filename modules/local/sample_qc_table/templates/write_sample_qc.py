#!/usr/bin/env python3
"""The stage-2b decision table (SAMPLE_QC_TABLE, PLAN §3 row 2b: "sample_qc.tsv: pass/fail + reason per sample; discovery and
every caller read it").

Nextflow module template (modules/local/sample_qc_table/main.nf): the Groovy placeholders are filled in by Nextflow, so the
task hash covers this file's content, not its path. No backslashes or dollar signs outside the placeholders; tab and newline
are chr(9) / chr(10).

Joins, per sample of the sample map [sample, role, donor], the MIN_COVERAGE table (required) with the panel tables of
COVERAGE_QC, RELATEDNESS_QC and DONOR_CONTENT_QC (each optional: absent when params.qc_panel is not set, since the blind panel
does not exist yet). Output <prefix>.sample_qc.tsv:
  sample role donor pass reasons notes mean_coverage pct_1x panel_qc panel_min_covered panel_contigs_below_floor
  kinship_own own_z closest_other_donor kinship_closest_other relatedness_reason donor_content donor_content_reason
pass = false when MIN_COVERAGE fails (always a failure, PLAN: excluded from all processing) or when a table named in
--fail-on (default relatedness,donor_content; panel_coverage may be added) flags the sample. Flags of tables not in
--fail-on go to notes, as "<table>:<reason>". panel_qc = run (all three panel tables), not_run (none) or partial.
A sample absent from min_coverage.tsv fails (not_in_min_coverage). Standard library only.
"""
import argparse
import json
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)

PREFIX = "${task.ext.prefix ?: meta.id}"
PROCESS = "${task.process}"
MIN_COVERAGE = "${min_coverage}".strip()
PANEL_COVERAGE = "${panel_coverage}".strip()
RELATEDNESS = "${relatedness}".strip()
DONOR_CONTENT = "${donor_content}".strip()
SAMPLE_MAP = json.loads('''${groovy.json.JsonOutput.toJson(sample_map)}''')  # [[sample, role, donor], ...]
EXT_ARGS = shlex.split('''${task.ext.args ?: ''}''')


def read_table(path):
    """TSV with a header -> list of dicts ([] when no file was given)."""
    if not path:
        return None
    with open(path) as fh:
        lines = [ln.rstrip(NL) for ln in fh if ln.strip()]
    if not lines:
        sys.exit(f"{PROCESS}: {path} is empty")
    hdr = lines[0].split(TAB)
    return [dict(zip(hdr, ln.split(TAB))) for ln in lines[1:]]


def by_sample(rows):
    out = {}
    for r in rows or []:
        out.setdefault(r["sample"], []).append(r)
    return out


def main():
    ap = argparse.ArgumentParser(description="SAMPLE_QC_TABLE options (task.ext.args)")
    ap.add_argument("--fail-on", default="relatedness,donor_content")
    a = ap.parse_args(EXT_ARGS)
    fail_on = {t.strip() for t in a.fail_on.split(",") if t.strip()}
    bad = fail_on - {"panel_coverage", "relatedness", "donor_content"}
    if bad:
        sys.exit(f"{PROCESS}: unknown --fail-on table(s) {sorted(bad)}")

    mc = by_sample(read_table(MIN_COVERAGE))
    pc_rows = read_table(PANEL_COVERAGE)
    rel_rows = read_table(RELATEDNESS)
    dc_rows = read_table(DONOR_CONTENT)
    given = [t is not None for t in (pc_rows, rel_rows, dc_rows)]
    panel_qc = "run" if all(given) else "not_run" if not any(given) else "partial"
    pc, rel, dc = by_sample(pc_rows), by_sample(rel_rows), by_sample(dc_rows)
    known = {s for s, _, _ in SAMPLE_MAP}
    for name, tab in (("min_coverage", mc), ("panel_coverage", pc), ("relatedness", rel), ("donor_content", dc)):
        extra = sorted(set(tab) - known)
        if extra:
            print(f"{PROCESS}: {name} has {len(extra)} samples not in the sample map (ignored): {extra[:5]}", file=sys.stderr)

    hdr = ["sample", "role", "donor", "pass", "reasons", "notes", "mean_coverage", "pct_1x", "panel_qc", "panel_min_covered",
           "panel_contigs_below_floor", "kinship_own", "own_z", "closest_other_donor", "kinship_closest_other",
           "relatedness_reason", "donor_content", "donor_content_reason"]
    n_fail = 0
    with open(f"{PREFIX}.sample_qc.tsv", "w") as out:
        out.write(TAB.join(hdr) + NL)
        for s, role, donor in SAMPLE_MAP:
            reasons = []
            notes = []
            m = mc.get(s)
            if not m:
                reasons.append("not_in_min_coverage")
                m = [{}]
            m = m[0]
            if m.get("pass") == "false":
                reasons.append(m.get("reason", "min_coverage"))

            def add(table, reason):
                (reasons if table in fail_on else notes).append(f"{table}:{reason}")

            p = pc.get(s, [])
            if pc_rows is not None:
                pmin = min((int(r["covered"]) for r in p), default=0)
                pbelow = sum(1 for r in p if r.get("below_min_markers") == "true")
                if pbelow or not p:
                    add("panel_coverage", "below_min_markers" if p else "not_counted")
            else:
                pmin, pbelow = "NA", "NA"
            r = (rel.get(s) or [{}])[0]
            if rel_rows is not None:
                if not r:
                    add("relatedness", "not_in_table")
                elif r.get("flag") == "true":
                    add("relatedness", r.get("reason", "flag"))
            d = (dc.get(s) or [{}])[0]
            if dc_rows is not None:
                if not d:
                    add("donor_content", "not_in_table")
                elif d.get("flag") == "true":
                    add("donor_content", d.get("reason", "flag"))
            ok = not reasons
            n_fail += not ok
            row = [s, role, donor or ".", str(ok).lower(), ",".join(reasons) or ".", ",".join(notes) or ".",
                   m.get("mean_coverage", "NA"), m.get("pct_1x", "NA"), panel_qc, str(pmin), str(pbelow),
                   r.get("kinship_own", "NA"), r.get("own_z", "NA"), r.get("closest_other_donor", "NA"),
                   r.get("kinship_closest_other", "NA"), r.get("reason", "NA"),
                   d.get("alt_read_fraction", "NA"), d.get("reason", "NA")]
            out.write(TAB.join(row) + NL)
    print(f"sample_qc_table {PREFIX}: {len(SAMPLE_MAP)} samples, {n_fail} fail, panel_qc {panel_qc}, "
          f"fail_on {sorted(fail_on)}")
    with open(f"{PREFIX}.sample_qc_table.versions.yml", "w") as fh:
        fh.write(f'"{PROCESS}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
