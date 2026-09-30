"""Unit tests of templates/build_marker_union.py (standard library; run: python3 -m unittest discover -s <this dir>).

The template is loaded with its Nextflow placeholders blanked (they are all read inside main()), so its functions are
tested directly on hand-built step-4 tables.
"""
import gzip
import os
import pathlib
import re
import tempfile
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "build_marker_union.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("build_marker_union")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
HEADER = "chrom\tpos\tref\talt\tn\ta\ttier\tflags\n"


def write_step4(path, rows):
    with gzip.open(path, "wt") as fh:
        fh.write(HEADER)
        for r in rows:
            fh.write("\t".join(map(str, r)) + "\n")


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class Region(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(M.parse_region("chr10"), ("chr10", 1, None))
        self.assertEqual(M.parse_region("chr10:1-20000000"), ("chr10", 1, 20000000))
        self.assertTrue(M.in_region("chr10", 20000000, ("chr10", 1, 20000000)))
        self.assertFalse(M.in_region("chr10", 20000001, ("chr10", 1, 20000000)))
        self.assertFalse(M.in_region("chr1", 5, ("chr10", 1, None)))


class AssignTables(unittest.TestCase):
    def test_longest_donor_prefix(self):
        files = ["step4/Zx.0540_P3.chr10.sites.tsv.gz", "step4/Zx.0540_P3b.chr10.sites.tsv.gz"]
        got = M.assign_tables(files, ["Zx.0540_P3", "Zx.0540_P3b"])
        self.assertEqual(got["Zx.0540_P3b"], files[1])
        self.assertEqual(got["Zx.0540_P3"], files[0])

    def test_missing_table_refused(self):
        with self.assertRaises(SystemExit):
            M.assign_tables(["step4/A.chr10.sites.tsv.gz"], ["A", "B"])


class Union(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.region = ("chr10", 1, 1000)
        write_step4(os.path.join(d, "A.t.gz"), [
            ("chr10", 100, "A", "G", 10, 3, "A", "."),
            ("chr10", 200, "C", "T", 10, 3, "A", "."),
            ("chr10", 300, "G", "A", 10, 0, "ref", "."),
            ("chr10", 400, "T", "TA", 10, 3, "A", "."),      # indel: ignored
            ("chr10", 5000, "A", "C", 10, 3, "A", "."),      # outside the region
        ])
        write_step4(os.path.join(d, "B.t.gz"), [
            ("chr10", 100, "A", "G", 10, 3, "A", "."),       # shared with A
            ("chr10", 200, "C", "G", 10, 3, "A", "."),       # other ALT at 200 -> multiallelic
            ("chr10", 300, "G", "A", 10, 3, "B", "."),       # tier B: not in the union
        ])
        write_step4(os.path.join(d, "R.t.gz"), [           # reference donor (whole chromosome)
            ("chr10", 300, "G", "A", 10, 3, "A", "."),
            ("chr10", 100, "A", "G", 10, 0, "ref", "."),
            ("chr10", 900, "A", "C", 10, 3, "A", "."),
            ("chr10", 50000, "A", "C", 10, 3, "A", "."),     # clipped
        ])
        self.kinds = {"A": "run", "B": "run", "R": "reference"}
        self.ta, self.tr = {}, {}
        for k in self.kinds:
            self.ta[k], self.tr[k], _ = M.read_step4(os.path.join(d, k + ".t.gz"), self.region)
        self.rows = M.build_union(self.ta, self.tr, self.kinds)

    def tearDown(self):
        self.tmp.cleanup()

    def test_rows(self):
        by = {(r["pos"], r["alt"]): r for r in self.rows}
        self.assertEqual(sorted(by), [(100, "G"), (200, "G"), (200, "T"), (300, "A"), (900, "C")])
        self.assertEqual(by[(100, "G")]["donors"], ["A", "B"])
        self.assertEqual(by[(100, "G")]["multiallelic"], 0)
        self.assertEqual(by[(200, "T")]["multiallelic"], 1)
        self.assertEqual(by[(200, "G")]["multiallelic"], 1)
        self.assertEqual(by[(300, "A")]["donors"], ["R"])
        self.assertEqual(by[(300, "A")]["donor_kind"], ["reference"])
        # R has tier ref at 100 G (and does not carry it): carried for the m of the step-1 prior
        self.assertEqual(by[(100, "G")]["ref_donors"], ["R"])
        self.assertEqual(by[(900, "C")]["ref_donors"], [])

    def test_per_donor_gaps(self):
        pd = {p["donor"]: p for p in M.per_donor_rows(self.rows, self.ta, self.kinds)}
        # non-multiallelic union alleles: 100G, 300A, 900C
        self.assertEqual(pd["A"]["union_alleles"], 3)
        self.assertEqual(pd["A"]["n_gaps"], 2)      # 300A, 900C
        self.assertEqual(pd["B"]["n_gaps"], 2)
        self.assertEqual(pd["A"]["shared"], 1)
        self.assertEqual(pd["A"]["multiallelic_own"], 1)
        self.assertEqual(pd["R"]["tierA"], 2)

    def test_single_donor_has_zero_gaps(self):
        ta = {"A": self.ta["A"]}
        rows = M.build_union(ta, {"A": self.tr["A"]}, {"A": "run"})
        pd = M.per_donor_rows(rows, ta, {"A": "run"})
        self.assertEqual(pd[0]["n_gaps"], 0)
        self.assertEqual(len(rows), 2)


if __name__ == "__main__":
    unittest.main()
