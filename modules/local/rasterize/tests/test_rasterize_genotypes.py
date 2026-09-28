"""Unit tests of templates/rasterize_genotypes.py: the Eq. S5.1 projection (python3 -m unittest discover -s <this dir>)."""
import pathlib
import re
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "rasterize_genotypes.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("rasterize_genotypes")
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


class Projection(unittest.TestCase):
    def test_three_cases(self):
        for x in (0, 1, 2):
            self.assertEqual(M.genotype(x, "ALT"), x)
            self.assertEqual(M.genotype(x, "REF"), 0)
        self.assertEqual(M.genotype(0, "NA"), 0)
        self.assertIsNone(M.genotype(1, "NA"))
        self.assertIsNone(M.genotype(2, "NA"))
        self.assertIsNone(M.genotype(None, "ALT"))

    def test_raster(self):
        alleles = [{"chrom": "chr10", "pos": 100, "ref": "A", "alt": "G", "D": "ALT", "p_alt": 1.0},
                   {"chrom": "chr10", "pos": 200, "ref": "A", "alt": "G", "D": "NA", "p_alt": 0.4},
                   {"chrom": "chr10", "pos": 300, "ref": "A", "alt": "G", "D": "REF", "p_alt": 0.001},
                   {"chrom": "chr10", "pos": 450, "ref": "A", "alt": "G", "D": "ALT", "p_alt": 0.9995}]
        seg = {"L1": {"10": ([1, 420], [(1, 400, 2), (420, 900, 0)])},
               "L2": {"10": ([1], [(1, 900, 1)])},
               "L3": {"10": ([1], [(1, 900, 2)])}}
        qc = {"L1": True, "L2": True, "L3": False, "L4": False}
        lines, out = M.raster(alleles, seg, qc)
        self.assertEqual(lines, ["L1", "L2", "L3", "L4"])
        self.assertEqual([v[1] for v in out["L1"]], [2, None, 0, 0])
        self.assertEqual([v[1] for v in out["L2"]], [1, None, 0, 1])
        self.assertEqual([v[1] for v in out["L3"]], [None] * 4)         # excluded by line QC
        self.assertEqual([v[1] for v in out["L4"]], [None] * 4)         # excluded, no segments
        self.assertEqual([v[2] for v in out["L1"]], [2.0, 0.8, 0.002, 0.0])
        self.assertAlmostEqual(out["L2"][3][2], 0.9995)

    def test_breakpoint_interval_is_unknown(self):
        seg = {"L1": {"10": ([1, 500], [(1, 400, 0), (500, 900, 2)])}}
        self.assertIsNone(M.ancestry(seg["L1"], "chr10", 450))
        self.assertEqual(M.ancestry(seg["L1"], "chr10", 500), 2)
        self.assertIsNone(M.ancestry(seg["L1"], "chr9", 500))


if __name__ == "__main__":
    unittest.main()
