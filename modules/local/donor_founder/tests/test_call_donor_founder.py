"""Unit tests of templates/call_donor_founder.py (python3 -m unittest discover -s <this dir>)."""
import math
import pathlib
import re
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "call_donor_founder.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("call_donor_founder")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
K = lambda p: ("chr10", p, "A", "G")


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class Calls(unittest.TestCase):
    def setUp(self):
        self.union = [(K(1), False), (K(2), False), (K(3), False), (K(4), False), (K(5), False), (K(6), True)]
        self.s1 = {K(1): ("own", "ALT", None), K(2): ("gap", "REF", -8.0), K(3): ("gap", "ALT", 7.5),
                   K(4): ("gap", "NA", 3.0), K(5): ("gap", "NA", 1.0)}
        self.s2 = {K(4): ("ALT", 8.0), K(5): ("undecided", 2.0)}

    def test_each_step(self):
        rows, cnt = M.found(self.union, self.s1, self.s2)
        got = {k[1]: (d, step) for k, d, step, _lo, _p in rows}
        self.assertEqual(got, {1: ("ALT", "own"), 2: ("REF", "step1_ref"), 3: ("ALT", "step1_alt"),
                               4: ("ALT", "step2_alt"), 5: ("NA", "missing"), 6: ("NA", "multiallelic")})
        p = {k[1]: pa for k, _d, _s, _lo, pa in rows}
        self.assertEqual(p[1], 1.0)
        self.assertAlmostEqual(p[4], 1 / (1 + math.exp(-8.0)))
        self.assertAlmostEqual(p[5], 1 / (1 + math.exp(-2.0)))          # step 2's combined log-odds
        self.assertIsNone(p[6])
        s = M.summary("D", cnt)
        self.assertEqual((s["gaps"], s["own"], s["step2_alt"]), (4, 1, 1))
        self.assertAlmostEqual(s["step1_share_of_gaps"], 0.5)
        self.assertAlmostEqual(s["step2_share_of_gaps"], 0.25)
        self.assertAlmostEqual(s["missing_share_of_union"], 0.2)

    def test_no_step2_uses_step1_logodds(self):
        rows, _c = M.found(self.union, self.s1, {})
        lo = {k[1]: x for k, _d, _s, x, _p in rows}
        self.assertEqual(lo[4], 3.0)

    def test_inconsistent_inputs_refused(self):
        with self.assertRaises(SystemExit):
            M.found(self.union, self.s1, {K(3): ("ALT", 9.0)})          # step 2 on a site step 1 called
        with self.assertRaises(SystemExit):
            M.found([(K(9), False)], self.s1, {})                        # union row without a step-1 row


if __name__ == "__main__":
    unittest.main()
