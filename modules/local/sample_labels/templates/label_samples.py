#!/usr/bin/env python3
"""Edge translation of one donor x region (SAMPLE_LABELS, stage 8; meta/PROVENANCE.md "Identifiers: one physical key, biology
in the registry"): every internal table is keyed by the well-level sample_id; the final outputs carry the short id.

Nextflow module template (modules/local/sample_labels/main.nf): no backslashes or dollar signs outside the placeholders;
tab / newline are chr(9) / chr(10). Every placeholder is read inside main(), so the functions are importable by the unit
tests (tests/test_label_samples.py). Standard library only.

Label of a sample_id, from ONE join on the current registry (meta/registry.csv), resolved columns only (meta/corrections.csv
applied by meta/build_samples.py; the raw columns stay as the sources give them):
  nil_id_resolved if non-empty, else pedigree_resolved (the line id, e.g. BC1 samples), else the sample_id itself
  (label_source sample_id_no_label); a sample without a registry row (the B73 controls) keeps its sample_id
  (sample_id_not_in_registry). A registry row marked exclude = TRUE is refused (an excluded well has no genotype).
  The labels table carries the resolved values in its nil_id / pedigree / donor columns and the row's correction_ids.
  Collision: when two samples of the unit get the same label (replicate wells share a nil_id), every one of them is
  labelled <label>_<sample_id> (deterministic) and the others are listed in the collision column of sample_labels.tsv.
  A registry donor that differs from the unit donor is refused (a relabelled well belongs to another unit).
Inputs (RASTERIZE, LINE_MARKER_QC, RTIGER, the workflow's exclusion table), relabelled column in brackets:
  genotypes long table [line]  ->  <prefix>.genotypes.tsv.gz         (sample_id column added after line)
  genotype matrix [header]     ->  <prefix>.genotypes.matrix.tsv.gz
  segments CSV [name]          ->  <prefix>.segments.csv             (for GENOTYPE_SUMMARY and CHROMOSOME_PAINTING)
  line_qc.tsv [sample]         ->  <prefix>.line_qc.tsv              (idem)
  exclusions.tsv [sample]      ->  <prefix>.exclusions.tsv           (sample_id column added after sample)
  <prefix>.sample_labels.tsv   sample_id label label_source collision nil_id pedigree donor taxon role correction_ids
                               registry registry_sha256 code_version, one row per sample of the unit (the listed sample ids plus
                               every id in the tables), sorted by sample_id
  <prefix>.sample_labels.versions.yml
The registry is recorded (path, sha256, repo commit), not guarded: reporting writes nothing to the store and the rule wants
the current registry.
"""
import argparse
import csv
import gzip
import hashlib
import io
import platform
import shlex
import sys

TAB = chr(9)
NL = chr(10)
DOT = "."
COLS = ["sample_id", "label", "label_source", "collision", "nil_id", "pedigree", "donor", "taxon", "role", "correction_ids",
        "registry", "registry_sha256", "code_version"]
# registry column -> labels-table column (the resolved identity; meta/PROVENANCE.md "Corrections are applied at the end")
RESOLVED = {"nil_id_resolved": "nil_id", "pedigree_resolved": "pedigree", "donor_resolved": "donor"}
REG_COLS = ["sample_id", "taxon", "role", "correction_ids", "exclude"] + list(RESOLVED)


class LabelError(Exception):
    pass


def log(msg):
    sys.stderr.write("[sample_labels] " + msg + NL)


def open_text(path):
    return gzip.open(path, "rt", newline="") if path.endswith(".gz") else open(path, newline="")


def gz_write(path):
    # mtime 0: byte-identical output for identical content (the header holds only the output name)
    return io.TextIOWrapper(gzip.GzipFile(path, "wb", mtime=0), newline="")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_registry(path):
    """{sample_id: row} of the registry CSV; row keys are the labels-table names (nil_id, pedigree, donor = the resolved
    columns), plus taxon, role, correction_ids and exclude (TRUE / FALSE / empty)."""
    with open(path, newline="") as fh:
        rd = csv.DictReader(fh)
        missing = [c for c in REG_COLS if c not in (rd.fieldnames or [])]
        if missing:
            raise LabelError(f"registry {path}: missing columns {missing}")
        reg = {}
        for r in rd:
            sid = r["sample_id"].strip()
            if sid in reg:
                raise LabelError(f"registry {path}: duplicate sample_id {sid}")
            reg[sid] = {RESOLVED.get(c, c): (r[c] or "").strip() for c in REG_COLS}
    return reg


def read_head(path):
    """(header fields, delimiter) of a table, (None, None) for an empty file."""
    with open_text(path) as fh:
        head = fh.readline()
    if not head:
        return None, None
    delim = TAB if TAB in head else ","
    return next(csv.reader([head], delimiter=delim)), delim


def column_ids(path, col):
    """Values of one column of a header table (empty file: [])."""
    head, delim = read_head(path)
    if head is None:
        return []
    if col not in head:
        raise LabelError(f"{path}: no column {col!r}")
    with open_text(path) as fh:
        return [r[col] for r in csv.DictReader(fh, delimiter=delim)]


def matrix_ids(path):
    head, _delim = read_head(path)
    return [] if head is None else head[4:]


def assign_labels(ids, registry, donor):
    """{sample_id: record} for every id; raises LabelError on a donor mismatch or an unresolvable collision."""
    rec = {}
    for sid in sorted(set(ids)):
        r = registry.get(sid)
        if r is None:
            base, src = sid, "sample_id_not_in_registry"
            r = {}
        elif r.get("nil_id"):
            base, src = r["nil_id"], "nil_id"
        elif r.get("pedigree"):
            base, src = r["pedigree"], "pedigree"
        else:
            base, src = sid, "sample_id_no_label"
        if r.get("exclude", "").upper() == "TRUE":
            raise LabelError(f"{sid}: excluded in the registry (exclude = TRUE)")
        if donor and r.get("donor") and r["donor"] != donor:
            raise LabelError(f"{sid}: registry donor " + r["donor"] + f" differs from the unit donor {donor}")
        if any(c in base for c in (TAB, NL, chr(13))):
            raise LabelError(f"{sid}: label {base!r} contains a tab or newline")
        rec[sid] = {"sample_id": sid, "label": base, "label_source": src, "collision": DOT,
                    "nil_id": r.get("nil_id", ""), "pedigree": r.get("pedigree", ""), "donor": r.get("donor", ""),
                    "taxon": r.get("taxon", ""), "role": r.get("role", ""), "correction_ids": r.get("correction_ids", "")}
    by = {}
    for sid, x in rec.items():
        by.setdefault(x["label"], []).append(sid)
    for base, sids in sorted(by.items()):
        if len(sids) > 1:
            for sid in sids:
                rec[sid]["label"] = f"{base}_{sid}"
                rec[sid]["collision"] = ",".join(s for s in sids if s != sid)
            log(f"label collision {base}: " + ", ".join(sids) + " -> suffixed with the sample_id")
    labels = [x["label"] for x in rec.values()]
    dup = sorted({v for v in labels if labels.count(v) > 1})
    if dup:
        raise LabelError(f"labels still not unique after the collision suffix: {dup}")
    return rec


def relabel_rows(path, out, col, labels, add_id_after=False, gz=False):
    """Copy a header table with column `col` relabelled; add_id_after inserts sample_id after it. Empty in -> empty out."""
    head, delim = read_head(path)
    opener = gz_write if gz else (lambda p: open(p, "w", newline=""))
    with opener(out) as o:
        if head is None:
            return 0
        if col not in head:
            raise LabelError(f"{path}: no column {col!r}")
        i = head.index(col)
        w = csv.writer(o, delimiter=delim, lineterminator=NL)
        n = 0
        with open_text(path) as fh:
            rd = csv.reader(fh, delimiter=delim)
            next(rd)
            w.writerow(head[:i + 1] + ["sample_id"] + head[i + 1:] if add_id_after else head)
            for row in rd:
                if not row:
                    continue
                sid = row[i]
                if sid not in labels:
                    raise LabelError(f"{path}: {sid} has no label (not in the matrix header, tables or sample list)")
                new = row[:i] + [labels[sid]] + ([sid] if add_id_after else []) + row[i + 1:]
                w.writerow(new)
                n += 1
    return n


def relabel_matrix(path, out, labels):
    head, _delim = read_head(path)
    with gz_write(out) as o:
        if head is None:
            return
        with open_text(path) as fh:
            fh.readline()
            o.write(TAB.join(head[:4] + [labels[s] for s in head[4:]]) + NL)
            for line in fh:
                o.write(line)


def parse_args(argv):
    return argparse.ArgumentParser(prog="label_samples.py").parse_args(argv)


def run(prefix, genotypes, matrix, segments, line_qc, exclusions, donor, sample_ids, registry, registry_source, code_version):
    reg = read_registry(registry)
    ids = (list(sample_ids) + matrix_ids(matrix) + column_ids(segments, "name") + column_ids(line_qc, "sample")
           + column_ids(exclusions, "sample"))
    rec = assign_labels(ids, reg, donor)
    labels = {sid: x["label"] for sid, x in rec.items()}
    n_gt = relabel_rows(genotypes, f"{prefix}.genotypes.tsv.gz", "line", labels, add_id_after=True, gz=True)
    relabel_matrix(matrix, f"{prefix}.genotypes.matrix.tsv.gz", labels)
    relabel_rows(segments, f"{prefix}.segments.csv", "name", labels)
    relabel_rows(line_qc, f"{prefix}.line_qc.tsv", "sample", labels)
    relabel_rows(exclusions, f"{prefix}.exclusions.tsv", "sample", labels, add_id_after=True)
    digest = sha256(registry)
    with open(f"{prefix}.sample_labels.tsv", "w", newline="") as o:
        o.write(TAB.join(COLS) + NL)
        for sid in sorted(rec):
            x = dict(rec[sid], registry=registry_source, registry_sha256=digest, code_version=code_version)
            o.write(TAB.join(x[c] if x[c] != "" else DOT for c in COLS) + NL)
    n_col = sum(1 for x in rec.values() if x["collision"] != DOT)
    by_src = {}
    for x in rec.values():
        by_src[x["label_source"]] = by_src.get(x["label_source"], 0) + 1
    sources = ", ".join(k + " " + str(v) for k, v in sorted(by_src.items()))
    log(f"{prefix}: {len(rec)} samples labelled ({sources}); "
        f"{n_col} in label collisions; {n_gt} genotype rows; registry {registry_source} sha256 {digest}; code {code_version}")
    return rec


def main():
    prefix = "${task.ext.prefix ?: meta.id}"
    process = "${task.process}"
    parse_args(shlex.split('''${task.ext.args ?: ''}'''))
    ids = [s for s in "${sample_ids.join(',')}".split(",") if s]
    try:
        run(prefix, "${genotypes}", "${matrix}", "${segments}", "${line_qc}", "${exclusions}", "${donor}", ids,
            "${registry}", "${registry_source}", "${code_version}")
    except LabelError as e:
        log("ERROR: " + str(e))
        sys.exit(1)
    with open(f"{prefix}.sample_labels.versions.yml", "w") as fh:
        fh.write(f'"{process}":{NL}    python: {platform.python_version()}{NL}')


if __name__ == "__main__":
    main()
