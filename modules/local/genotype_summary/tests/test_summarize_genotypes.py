"""Unit tests of templates/summarize_genotypes.py (python3 -m unittest discover -s <this dir>)."""
import math
import pathlib
import re
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "summarize_genotypes.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("summarize_genotypes")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class Expectation(unittest.TestCase):
    def test_bc2s2_and_bc2s3(self):
        for e in M.EXPECT.values():
            self.assertAlmostEqual(sum(e), 1.0)
            self.assertAlmostEqual(e[1] / 2 + e[2], 1 / 8)              # donor allele frequency 12.5 %
        self.assertEqual(M.EXPECT["bc2s2"][1:], (1 / 16, 3 / 32))

    def test_chi2(self):
        e = M.EXPECT["bc2s2"]
        stat, p = M.chi2_2df([27, 2, 3], e)                               # n = 32 at the expectation exactly
        self.assertAlmostEqual(stat, 0.0)
        self.assertAlmostEqual(p, 1.0)
        stat, p = M.chi2_2df([22, 5, 5], e)
        want = (22 - 27) ** 2 / 27 + (5 - 2) ** 2 / 2 + (5 - 3) ** 2 / 3
        self.assertAlmostEqual(stat, want)
        self.assertAlmostEqual(p, math.exp(-want / 2))


class Tables(unittest.TestCase):
    def setUp(self):
        k = lambda p: ("chr10", p, "A", "G")
        self.alleles = [{"key": k(p), "D": d, "call_step": s} for p, d, s in [
            (100, "ALT", "own"), (200, "ALT", "own"), (300, "NA", "missing"), (400, "ALT", "step2_alt"),
            (500, "ALT", "own"), (600, "REF", "step1_ref"), (700, "NA", "multiallelic")]]
        self.seg = {"L1": [(1, 250, 0), (350, 900, 2)], "L2": [(1, 900, 1)]}
        self.geno = {"L1": {k(100): (0, 0), k(200): (0, 0), k(300): (None, None), k(400): (2, 2), k(500): (2, 2),
                            k(600): (2, 0)},
                     "L2": {k(100): (1, 1), k(200): (1, 1), k(300): (1, None), k(400): (1, 1), k(500): (1, 1),
                            k(600): (1, 0)}}

    def test_line_summary(self):
        rows = {r["line"]: r for r in M.line_summary(self.seg, self.geno, {}, M.EXPECT["bc2s2"])}
        self.assertAlmostEqual(rows["L1"]["mb_x0"], 250 / 1e6)
        self.assertAlmostEqual(rows["L1"]["mb_x2"], 551 / 1e6)
        self.assertEqual((rows["L1"]["sites_gt0"], rows["L1"]["sites_gt2"], rows["L1"]["sites_na"]), (3, 2, 1))
        self.assertAlmostEqual(rows["L1"]["no_call_share"], 1 / 6)
        self.assertEqual(rows["ALL"]["sites"], 12)

    def test_single_locus(self):
        rows = {r["pos"]: r for r in M.single_locus(self.alleles, self.geno, {}, M.EXPECT["bc2s2"])}
        self.assertNotIn(700, rows)
        self.assertEqual((rows[400]["n_x0"], rows[400]["n_x1"], rows[400]["n_x2"]), (0, 1, 1))
        self.assertAlmostEqual(rows[400]["donor_freq"], 3 / 4)
        self.assertEqual(rows[300]["n_lines"], 1)                          # L1 has no x at 300

    def test_breakpoint_density(self):
        # markers (own) at 100, 200, 500; L1 breakpoint at (250 + 350) / 2 = 300 -> marker index 2
        rows, n_markers = M.breakpoint_density(self.alleles, self.seg, {}, 0)
        self.assertEqual(n_markers, 3)
        r = {x["line"]: x for x in rows}
        self.assertEqual(r["L1"]["n_breakpoints"], 1)
        # gap sites 300 (idx 2), 400 (idx 2, step 2), 600 (idx 3): window 0 -> 300 and 400 near, 600 far
        self.assertEqual((r["L1"]["gap_sites_near"], r["L1"]["step2_near"], r["L1"]["gap_sites_far"]), (2, 1, 1))
        self.assertEqual(r["L2"]["n_breakpoints"], 0)
        self.assertEqual(r["L2"]["gap_sites_far"], 3)
        self.assertEqual(r["ALL"]["gap_sites_near"], 2)


if __name__ == "__main__":
    unittest.main()
