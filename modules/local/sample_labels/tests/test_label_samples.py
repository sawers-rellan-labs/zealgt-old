"""Unit tests of templates/label_samples.py (python3 -m unittest discover -s <this dir>)."""
import csv
import gzip
import os
import pathlib
import re
import tempfile
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "label_samples.py"
DATA = pathlib.Path(__file__).resolve().parent / "data"
UNIT = "Zx.0001_P1.chrA_1-5000"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("label_samples")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
REG = M.read_registry(str(DATA / "registry.csv"))


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class Labels(unittest.TestCase):
    def test_rule_and_fallbacks(self):
        rec = M.assign_labels(["PN1_SID1", "PN1_SID4", "S_1A_1", "B73_X"], REG, "Zx.0001_P1")
        self.assertEqual({s: (r["label"], r["label_source"]) for s, r in rec.items()}, {
            "PN1_SID1": ("Zx00011111", "nil_id"),
            "PN1_SID4": ("Zx.0001_P1-bulk", "pedigree"),
            "S_1A_1": ("Zx.0001_P1_P1", "pedigree"),
            "B73_X": ("B73_X", "sample_id_not_in_registry"),
        })

    def test_collision_suffix_is_deterministic(self):
        for order in (["PN1_SID2", "PN1_SID3"], ["PN1_SID3", "PN1_SID2"]):
            rec = M.assign_labels(order, REG, "Zx.0001_P1")
            self.assertEqual(rec["PN1_SID2"]["label"], "Zx00012222_PN1_SID2")
            self.assertEqual(rec["PN1_SID3"]["label"], "Zx00012222_PN1_SID3")
            self.assertEqual(rec["PN1_SID2"]["collision"], "PN1_SID3")

    def test_label_equal_to_another_sample_id_collides(self):
        reg = dict(REG, PN1_SID7={"sample_id": "PN1_SID7", "nil_id": "B73_X", "pedigree": "", "donor": "", "taxon": "", "role": ""})
        rec = M.assign_labels(["PN1_SID7", "B73_X"], reg, "Zx.0001_P1")
        self.assertEqual(rec["B73_X"]["label"], "B73_X_B73_X")
        self.assertEqual(rec["PN1_SID7"]["label"], "B73_X_PN1_SID7")

    def test_resolved_columns_and_corrections(self):
        # PN1_SID5: raw donor Zx.0009_P1 / nil Zx00093333, corrected (C0001) to Zx.0001_P1 / Zx00013333
        rec = M.assign_labels(["PN1_SID5"], REG, "Zx.0001_P1")
        x = rec["PN1_SID5"]
        self.assertEqual((x["label"], x["nil_id"], x["pedigree"], x["donor"], x["correction_ids"]),
                         ("Zx00013333", "Zx00013333", "Zx.0001_P1-3", "Zx.0001_P1", "C0001"))

    def test_missing_resolved_column_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "samples.csv")
            with open(p, "w") as fh:
                fh.write("sample_id,role,donor,taxon,nil_id,pedigree" + chr(10))
            with self.assertRaises(M.LabelError):
                M.read_registry(p)

    def test_excluded_well_refused(self):
        with self.assertRaises(M.LabelError):
            M.assign_labels(["PN1_SID6"], REG, "Zx.0001_P1")

    def test_donor_mismatch_refused(self):
        with self.assertRaises(M.LabelError):
            M.assign_labels(["PN9_SID9"], REG, "Zx.0001_P1")


class Run(unittest.TestCase):
    def test_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                rec = M.run(UNIT, str(DATA / f"{UNIT}.genotypes.tsv.gz"), str(DATA / f"{UNIT}.genotypes.matrix.tsv.gz"),
                            str(DATA / f"{UNIT}.segments.csv"), str(DATA / f"{UNIT}.line_qc.tsv"),
                            str(DATA / f"{UNIT}.exclusions.tsv"), "Zx.0001_P1", ["B73_X"], str(DATA / "registry.csv"),
                            "tests/data/registry.csv", "abc123")
                with gzip.open(f"{UNIT}.genotypes.tsv.gz", "rt") as fh:
                    gt = list(csv.DictReader(fh, delimiter="\t"))
                with gzip.open(f"{UNIT}.genotypes.matrix.tsv.gz", "rt") as fh:
                    head = fh.readline().rstrip("\n").split("\t")
                with open(f"{UNIT}.sample_labels.tsv") as fh:
                    lab = list(csv.DictReader(fh, delimiter="\t"))
                with open(f"{UNIT}.exclusions.tsv") as fh:
                    ex = fh.read().splitlines()
            finally:
                os.chdir(cwd)
        self.assertEqual(len(rec), 6)
        self.assertEqual(gt[0]["line"], "Zx00011111")
        self.assertEqual(gt[0]["sample_id"], "PN1_SID1")
        self.assertEqual(head[4:], ["Zx00011111", "Zx00012222_PN1_SID2", "Zx00012222_PN1_SID3", "Zx.0001_P1-bulk"])
        self.assertEqual(ex[0], "sample\tsample_id\trole\tstage\treason")
        self.assertEqual(ex[1].split("\t")[:2], ["Zx.0001_P1_P1", "S_1A_1"])
        b73 = [r for r in lab if r["sample_id"] == "B73_X"][0]
        self.assertEqual((b73["label"], b73["nil_id"], b73["code_version"]), ("B73_X", ".", "abc123"))
        self.assertEqual(len({r["registry_sha256"] for r in lab}), 1)


if __name__ == "__main__":
    unittest.main()
