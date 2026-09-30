"""Unit tests of templates/fill_gaps_bc1.py: the step-1 cut-offs and the Eq. S5.3 prior against hand-computed cases.

Run: python3 -m unittest discover -s <this dir>. The template is loaded with its Nextflow placeholders blanked.
"""
import gzip
import math
import os
import pathlib
import re
import tempfile
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "fill_gaps_bc1.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("fill_gaps_bc1")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
LOGIT_0999 = math.log(999.0)  # logit(0.999) = 6.906754778648553


def rec(llr, n, tier="-", flags="."):
    return {"llr": llr, "n": n, "a": 0, "tier": tier, "flags": flags, "n_pools_alt": 0, "n0": 50, "a0": 0, "eps": 0.005}


def urow(pos, carriers, reference=(), ref_donors=(), multi=False):
    return {"key": ("chr10", pos, "A", "G"), "carriers": set(carriers), "reference_carriers": set(reference),
            "ref_donors": set(ref_donors), "multiallelic": multi}


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class CutOffs(unittest.TestCase):
    """REF if LLR <= -4 and pooled depth >= 12; ALT if logodds >= logit(0.999); flags block ALT."""

    def setUp(self):
        self.a = M.parse_args([])

    def test_ref_rule(self):
        self.assertEqual(M.call_gap(rec(-4.0, 12), 0.5, self.a)[0], "REF")
        self.assertEqual(M.call_gap(rec(-4.0, 11), 0.5, self.a)[:2], ("NA", "below_cutoff"))
        self.assertEqual(M.call_gap(rec(-3.99, 50), 0.5, self.a)[:2], ("NA", "below_cutoff"))
        self.assertEqual(M.call_gap(rec(-10.0, 12), 0.5, self.a)[0], "REF")

    def test_alt_cutoff_on_log_odds(self):
        # pi = 0.5: logit 0, so ALT iff LLR >= log(999) = 6.9068 (posterior 0.99899 at LLR 6.9 prints as 0.9990)
        self.assertEqual(M.call_gap(rec(6.9, 30), 0.5, self.a)[:2], ("NA", "below_cutoff"))
        self.assertEqual(M.call_gap(rec(6.907, 30), 0.5, self.a)[:2], ("ALT", "posterior"))
        # pi = 2/3: logit = log 2, so LLR >= 6.2137 is needed
        self.assertEqual(M.call_gap(rec(6.21, 30), 2 / 3, self.a)[0], "NA")
        self.assertEqual(M.call_gap(rec(6.22, 30), 2 / 3, self.a)[0], "ALT")
        _s, _r, lo = M.call_gap(rec(6.22, 30), 2 / 3, self.a)
        self.assertAlmostEqual(lo, 6.22 + math.log(2), places=12)

    def test_flags_never_promoted(self):
        for f in ("hidepth", "af_gt_half", "hidepth,single_sample"):
            self.assertEqual(M.call_gap(rec(12.0, 30, "B", f), 0.9, self.a)[:2], ("NA", "blocked_flag"))
        # other flags do not block
        self.assertEqual(M.call_gap(rec(12.0, 30, "B", "single_sample"), 0.5, self.a)[0], "ALT")
        # a REF call is not blocked by a flag (dhd_bayes: tier ref -> REF first)
        self.assertEqual(M.call_gap(rec(-6.0, 30, "ref", "hidepth"), 0.5, self.a)[0], "REF")

    def test_absent(self):
        s, r, lo = M.call_gap(None, 0.75, self.a)
        self.assertEqual((s, r), ("NA", "absent"))
        self.assertAlmostEqual(lo, math.log(3))


class Prior(unittest.TestCase):
    """Two run donors D1, D2 and one reference donor R (hand-computed pi = (w mu + k) / (w + m), w = 2)."""

    def setUp(self):
        self.union = [
            urow(1, ["D2", "R"], reference=["R"]),        # D1 gap; k = 2, m = 2
            urow(2, ["D1"]),                              # D1 own; D2 gap (absent)
            urow(3, ["R"], reference=["R"]),              # gap for both; D2 REF at 3
            urow(4, ["D2"], ref_donors=["R"]),            # D1 gap (REF); R has tier ref at 4
            urow(5, ["D1", "D2"], multi=True),            # multiallelic: skipped
        ]
        k = lambda p: ("chr10", p, "A", "G")
        self.joint = {
            "D1": {k(1): rec(6.0, 30, "B"), k(2): rec(9.0, 40, "A"), k(3): rec(8.0, 40, "A"), k(4): rec(-5.0, 20, "ref")},
            "D2": {k(1): rec(9.0, 40, "A"), k(3): rec(-6.0, 30, "ref"), k(4): rec(9.0, 40, "A")},
        }
        self.a = M.parse_args([])

    def rows(self, **kw):
        a = M.parse_args(sum(([f"--{k.replace('_', '-')}", str(v)] for k, v in kw.items()), []))
        rows, summ = M.fill(self.union, self.joint, ["D1", "D2"], {"D1": "Zx", "D2": "Zd", "R": "Zx"}, a)
        return {(r["donor"], r["key"][1]): r for r in rows}, {s["donor"]: s for s in summ}

    def test_mu(self):
        # D1 gaps: 1 (tier B), 3 (tier A), 4 (REF): A = 1, R = 1 -> (1 + 0.5) / (1 + 1 + 1) = 0.5
        self.assertAlmostEqual(M.sharing_rate("D1", self.union, self.joint, self.a)[0], 0.5)
        # D2 gaps: 2 (absent), 3 (REF): A = 0, R = 1 -> 0.5 / 2 = 0.25
        self.assertAlmostEqual(M.sharing_rate("D2", self.union, self.joint, self.a)[0], 0.25)

    def test_other_donors(self):
        rows, summ = self.rows()
        r = rows[("D1", 1)]
        self.assertEqual((r["k"], r["m"]), (2, 2))
        self.assertAlmostEqual(r["prior"], 0.75)                      # (2 * 0.5 + 2) / (2 + 2)
        self.assertAlmostEqual(r["logodds"], 6.0 + math.log(3))       # 7.0986 >= 6.9068
        self.assertEqual(r["state"], "ALT")
        r = rows[("D1", 3)]
        self.assertEqual((r["k"], r["m"]), (1, 2))                    # R carries; D2 REF at 3
        self.assertAlmostEqual(r["prior"], 0.5)
        r = rows[("D1", 4)]
        self.assertEqual((r["k"], r["m"]), (1, 2))                    # D2 carries; R tier ref (ref_donors)
        self.assertEqual(r["state"], "REF")
        r = rows[("D2", 2)]                                           # absent: pi = (2 * 0.25 + 1) / (2 + 1)
        self.assertEqual((r["state"], r["reason"]), ("NA", "absent"))
        self.assertAlmostEqual(r["prior"], 0.5)
        self.assertEqual(rows[("D1", 2)]["state"], "ALT")
        self.assertEqual(rows[("D1", 2)]["src"], "own")
        self.assertNotIn(("D1", 5), rows)
        self.assertEqual(summ["D1"]["multiallelic_skipped"], 1)
        self.assertEqual(summ["D1"]["prior_donors"], "D2,R")
        self.assertEqual((summ["D1"]["own"], summ["D1"]["gaps"], summ["D1"]["ALT"], summ["D1"]["REF"]), (1, 3, 2, 1))

    def test_below_cutoff_with_smaller_prior(self):
        self.joint["D1"][("chr10", 1, "A", "G")] = rec(5.8, 30, "B")  # 5.8 + log 3 = 6.899 < 6.9068
        rows, _s = self.rows()
        self.assertEqual((rows[("D1", 1)]["state"], rows[("D1", 1)]["reason"]), ("NA", "below_cutoff"))

    def test_same_taxon(self):
        rows, summ = self.rows(gap_prior_scope="same_taxon")
        self.assertEqual(summ["D1"]["prior_donors"], "R")                # D2 is Zd
        r = rows[("D1", 1)]
        self.assertEqual((r["k"], r["m"]), (1, 1))
        self.assertAlmostEqual(r["prior"], (2 * 0.5 + 1) / 3)
        self.assertEqual(summ["D2"]["prior_source_used"], "mu_only (no prior donors)")

    def test_fixed_and_mu_only(self):
        rows, summ = self.rows(gap_prior_source="fixed", gap_prior_fixed=0.1)
        self.assertAlmostEqual(rows[("D1", 1)]["prior"], 0.1)
        self.assertIsNone(rows[("D1", 1)]["k"])
        self.assertEqual(rows[("D1", 1)]["state"], "NA")                 # 6.0 + logit 0.1 = 3.80
        rows, summ = self.rows(gap_prior_source="mu_only")
        self.assertAlmostEqual(rows[("D1", 1)]["prior"], 0.5)
        self.assertAlmostEqual(rows[("D2", 2)]["prior"], 0.25)


class SingleDonor(unittest.TestCase):
    def test_zero_gaps_no_crash(self):
        union = [urow(1, ["D1"]), urow(2, ["D1"])]
        joint = {"D1": {}}
        rows, summ = M.fill(union, joint, ["D1"], {}, M.parse_args([]))
        self.assertEqual(summ[0]["gaps"], 0)
        self.assertEqual(summ[0]["own"], 2)
        self.assertEqual(summ[0]["prior_source_used"], "mu_only (no prior donors)")
        self.assertTrue(all(r["state"] == "ALT" for r in rows))

    def test_reference_donor_gives_gaps(self):
        union = [urow(1, ["D1"]), urow(2, ["R"], reference=["R"])]
        joint = {"D1": {("chr10", 2, "A", "G"): rec(4.0, 30, "C")}}
        rows, summ = M.fill(union, joint, ["D1"], {}, M.parse_args([]))
        self.assertEqual(summ[0]["gaps"], 1)
        self.assertEqual(summ[0]["prior_donors"], "R")
        r = [x for x in rows if x["key"][1] == 2][0]
        # mu = (0 + 0.5) / (0 + 0 + 1) = 0.5; k = 1, m = 1: pi = (1 + 1) / 3 = 2/3; 4.0 + log 2 < cut-off
        self.assertAlmostEqual(r["prior"], 2 / 3)
        self.assertEqual(r["state"], "NA")


class JointTable(unittest.TestCase):
    def test_llr_from_logodds_at_full_precision(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "D1.chr10.sites.tsv.gz")
            with gzip.open(p, "wt") as fh:
                fh.write("chrom\tpos\tref\talt\tn\ta\tn_pools_alt\teps\tLLR\ttier\tflags\tn0\ta0\tlogodds\n")
                # printed LLR 6.91 would pass the cut-off; the full-precision value 6.9064 does not
                fh.write("chr10\t1\tA\tG\t30\t5\t2\t0.005\t6.91\tB\t.\t80\t1\t6.9064\n")
            t = M.read_joint(p, 0.5)
            r = t[("chr10", 1, "A", "G")]
            self.assertAlmostEqual(r["llr"], 6.9064)
            self.assertEqual((r["n0"], r["a0"]), (80, 1))
            self.assertEqual(M.call_gap(r, 0.5, M.parse_args([]))[0], "NA")
            with self.assertRaises(SystemExit):     # tier_prior differs from the step-4 run
                M.read_joint(p, 0.9)


if __name__ == "__main__":
    unittest.main()
