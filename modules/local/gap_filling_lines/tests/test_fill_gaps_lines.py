"""Unit tests of templates/fill_gaps_lines.py: the step-2 line model, the review #1 fixes and the additive cut-off against
hand-computed cases. Run: python3 -m unittest discover -s <this dir>. The template is loaded with its placeholders blanked.
"""
import gzip
import math
import os
import pathlib
import re
import tempfile
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "fill_gaps_lines.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("fill_gaps_lines")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
A = M.parse_args([])                  # alpha 1, beta 200, b73_lines_alt_p 0.01, gap_alt_posterior 0.999
ONE = ([1.0], [0.0])                  # a one-point c prior at c = 1


def cand(prior=0.5, llr=None, n0=0, a0=0, reason="below_cutoff", flags="."):
    return {"key": ("chr10", 100, "A", "G"), "src": "gap", "state": "NA", "reason": reason, "flags": flags,
            "prior": prior, "llr": llr, "n0": n0, "a0": a0}


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class LineModel(unittest.TestCase):
    def test_one_alt_read_in_a_donor_line(self):
        # x = 2 line: 1 read, ALT; x = 0 line: 1 read, REF; lambda 1 each; c = 1.
        # depth terms are equal under both hypotheses; rho = 1 -> LLR = log((1 - eps) / eps)
        eps = 1 / 201
        llr, ks = M.llr_lines([1, 1], [1, 0], [2, 0], [1.0, 1.0], eps, *ONE, 0.02)
        self.assertAlmostEqual(llr, math.log(200))
        self.assertAlmostEqual(ks, 1.0)

    def test_c_summed_out_het_line(self):
        # x = 1 line with 1 ALT read, x = 0 line with 1 REF read, grid c in {0.5, 1} with equal weight, lambda 1, ks = 1
        eps = 0.005
        grid, logw = [0.5, 1.0], [math.log(0.5)] * 2
        llr, _ks = M.llr_lines([1, 1], [1, 0], [1, 0], [1.0, 1.0], eps, grid, logw, 0.02)
        dep = [math.log(0.5) + (math.log(0.5 + 0.5 * c) - (0.5 + 0.5 * c)) + (math.log(1.0) - 1.0) for c in grid]
        rho = [c / (1 + c) for c in grid]
        l_alt = math.log(sum(math.exp(d + math.log(r * (1 - eps) + (1 - r) * eps) + math.log(1 - eps))
                             for d, r in zip(dep, rho)))
        l_ref = math.log(sum(math.exp(d) for d in dep)) + math.log(eps) + math.log(1 - eps)
        self.assertAlmostEqual(llr, l_alt - l_ref, places=10)

    def test_depth_scale_floor(self):
        # no reads in the x = 0 line: ks = max(0 / 1, 0.02) = 0.02
        _llr, ks = M.llr_lines([1, 0], [1, 0], [2, 0], [1.0, 1.0], 0.005, *ONE, 0.02)
        self.assertAlmostEqual(ks, 0.02)

    def test_no_test_without_donor_line_or_depth_scale(self):
        self.assertIsNone(M.llr_lines([3, 2], [0, 0], [0, 0], [1.0, 1.0], 0.005, *ONE, 0.02))
        self.assertIsNone(M.llr_lines([3], [1], [2], [1.0], 0.005, *ONE, 0.02))


class Candidate(unittest.TestCase):
    def test_additive_cut_off(self):
        # one ALT read in an x = 2 line: LLR_lines = log 200 = 5.298; + LLR_BC1 2 = 7.298 >= 6.907 -> ALT
        r = M.score_candidate(cand(0.5, 2.0), [1, 1], [1, 0], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertAlmostEqual(r["eps_s"], 1 / 201)
        self.assertAlmostEqual(r["logodds_combined"], 2.0 + math.log(200))
        self.assertEqual(r["call"], "ALT")
        r = M.score_candidate(cand(0.5, 1.0), [1, 1], [1, 0], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertEqual(r["call"], "undecided")                          # 6.298 < 6.907
        # prior 2/3 and no BC1 read (LLR_BC1 = 0): log 2 + log 200 = 5.99 -> undecided (a single read never suffices)
        r = M.score_candidate(cand(2 / 3, None), [1, 1], [1, 0], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertAlmostEqual(r["logodds_combined"], math.log(2) + math.log(200))
        self.assertEqual(r["call"], "undecided")

    def test_x0_alt_read_raises_eps(self):
        # review #1b: the x = 0 line's ALT read is a zero-class read: eps_s = (0 + 1 + 1) / (0 + 1 + 200)
        # (one ALT read of one is not significant: P(X >= 1 | 1, 1/200) = 0.005 < 0.01 would block, so use n0 = 300)
        r = M.score_candidate(cand(0.5, 2.0, n0=300, a0=0), [1, 1], [1, 1], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertAlmostEqual(r["eps0"], 1 / 500)
        self.assertAlmostEqual(r["p_b73_lines"], 1 / 500)
        self.assertEqual(r["call"], "blocked_b73_lines")
        a = M.parse_args(["--b73-lines-alt-p", "0.001"])
        r = M.score_candidate(cand(0.5, 2.0, n0=300, a0=0), [1, 1], [1, 1], [2, 0], [1.0, 1.0], *ONE, a)
        eps_s = 2 / 501
        self.assertAlmostEqual(r["eps_s"], eps_s)
        self.assertAlmostEqual(r["llr_lines"], math.log((1 - eps_s) / eps_s))   # smaller than log(500 / 1 - 1)
        self.assertEqual(r["call"], "ALT")                                   # 2 + 5.52 = 7.52
        r0 = M.score_candidate(cand(0.5, 2.0, n0=300, a0=0), [1, 1], [1, 0], [2, 0], [1.0, 1.0], *ONE, a)
        self.assertGreater(r0["llr_lines"], r["llr_lines"])

    def test_blocked_b73_lines(self):
        # x = 0 lines 3 ALT of 10 reads, zero class 0 of 100: eps0 = 1 / 300; P(X >= 3 | 10, 1/300)
        p = 1 / 300
        sf = 1 - sum(math.comb(10, k) * p ** k * (1 - p) ** (10 - k) for k in range(3))
        r = M.score_candidate(cand(0.5, 9.0, n0=100, a0=0), [2, 10], [2, 3], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertAlmostEqual(r["p_b73_lines"], sf, places=12)
        self.assertLess(sf, 1e-5)
        self.assertEqual(r["call"], "blocked_b73_lines")
        self.assertEqual((r["n0_lines"], r["a0_lines"]), (10, 3))

    def test_flagged_site_never_promoted(self):
        # review #1a: whatever the evidence, a site step 1 blocked for a flag stays blocked
        r = M.score_candidate(cand(0.9, 20.0, reason="blocked_flag", flags="hidepth"), [5, 1], [5, 0], [2, 0],
                              [1.0, 1.0], *ONE, A)
        self.assertEqual(r["call"], "blocked_flag")
        r = M.score_candidate(cand(0.9, 20.0, reason="absent", flags="af_gt_half"), [5, 1], [5, 0], [2, 0],
                              [1.0, 1.0], *ONE, A)
        self.assertEqual(r["call"], "blocked_flag")

    def test_never_ref(self):
        # many REF reads in donor lines give a very negative LLR_lines but the call is undecided, never REF
        r = M.score_candidate(cand(0.5, 0.0), [40, 40], [0, 0], [2, 0], [1.0, 1.0], *ONE, A)
        self.assertLess(r["llr_lines"], -50)
        self.assertEqual(r["call"], "undecided")


class Helpers(unittest.TestCase):
    def test_binom_sf(self):
        self.assertAlmostEqual(M.binom_sf(1, 1, 0.2), 0.2)
        self.assertAlmostEqual(M.binom_sf(0, 5, 0.2), 1.0)
        self.assertAlmostEqual(M.binom_sf(2, 3, 0.5), 0.5)
        self.assertEqual(M.binom_sf(4, 3, 0.5), 0.0)

    def test_ad_name(self):
        self.assertEqual(M.ad_name("[5]PN5_SID464:AD"), "PN5_SID464")
        self.assertEqual(M.ad_name("# [1]CHROM"), "CHROM")
        self.assertEqual(M.ad_name("S_2A_11:AD"), "S_2A_11")

    def test_site_counts_match_alt(self):
        t = {("chr10", 100): ("A", ["C", "G", "<*>"], [[5, 1, 2, 0], [], [3, 0]])}
        self.assertEqual(M.site_counts(t, ("chr10", 100, "A", "G"), 3), ([7, 0, 3], [2, 0, 0]))
        self.assertEqual(M.site_counts(t, ("chr10", 100, "A", "T"), 3), ([5, 0, 3], [0, 0, 0]))
        self.assertEqual(M.site_counts(t, ("chr10", 101, "A", "G"), 3), ([0, 0, 0], [0, 0, 0]))

    def test_ancestry_outside_segments(self):
        seg = {"L1": ([1, 500], [(1, 400, 0), (500, 900, 2)])}
        self.assertEqual(M.ancestry(seg, "L1", 400), 0)
        self.assertEqual(M.ancestry(seg, "L1", 450), -1)   # breakpoint interval
        self.assertEqual(M.ancestry(seg, "L1", 500), 2)
        self.assertEqual(M.ancestry(seg, "L1", 901), -1)
        self.assertEqual(M.ancestry(seg, "L2", 450), -1)

    def test_flat_prior_grid(self):
        grid, logw = M.read_c_prior("", "flat", 1.5, 0.05)
        self.assertEqual(len(grid), 31)
        self.assertAlmostEqual(grid[-1], 1.5)
        self.assertAlmostEqual(sum(math.exp(w) for w in logw), 1.0)
        with self.assertRaises(SystemExit):
            M.read_c_prior("", "taxon", 1.5, 0.05)


class Run(unittest.TestCase):
    """End-to-end on files: 3 lines (L1 x = 2 at 100, L2 x = 0, L3 excluded by line QC), 2 union sites."""

    def test_run(self):
        with tempfile.TemporaryDirectory() as d:
            ad = os.path.join(d, "lines.ad.tsv.gz")
            with gzip.open(ad, "wt") as fh:
                fh.write("# [1]CHROM\t[2]POS\t[3]REF\t[4]ALT\t[5]L1:AD\t[6]L2:AD\t[7]L3:AD\n")
                fh.write("chr10\t100\tA\tG,<*>\t0,1,0\t1,0,0\t0,5,0\n")
                fh.write("chr10\t200\tC\t<*>\t1,0\t1,0\t1,0\n")
            seg = os.path.join(d, "seg.csv")
            with open(seg, "w") as fh:
                fh.write("source,donor,name,chr,start_bp,end_bp,state\n")
                fh.write("RTIGER,D,L1,10,1,150,2\nRTIGER,D,L1,10,180,300,0\nRTIGER,D,L2,10,1,300,0\nRTIGER,D,L3,10,1,300,2\n")
            qc = os.path.join(d, "line_qc.tsv")
            with open(qc, "w") as fh:
                fh.write("sample\tpass\nL1\tTRUE\nL2\tTRUE\nL3\tFALSE\n")
            rows = [cand(0.5, 2.0), {"key": ("chr10", 200, "C", "T"), "src": "own", "state": "ALT", "reason": "own",
                                     "flags": ".", "prior": None, "llr": None, "n0": None, "a0": None}]
            names, t = M.read_ad(ad)
            self.assertEqual(names, ["L1", "L2", "L3"])
            out, summ = M.run(rows, names, t, M.read_segments(seg, "chr10"), M.read_line_qc(qc), *ONE, A)
            # lambda (all union sites where x = 0): L1 -> site 200 only: 1; L2 -> sites 100, 200: (1 + 1) / 2 = 1
            self.assertEqual(summ["lines_used"], 2)
            self.assertEqual(summ["lines_excluded_qc"], 1)
            self.assertEqual(summ["candidates"], 1)
            _key, r = out[0]
            self.assertAlmostEqual(r["llr_lines"], math.log(200))  # L3's 5 ALT reads are not used (excluded line)
            self.assertEqual(r["call"], "ALT")
            self.assertEqual(summ["ALT"], 1)


if __name__ == "__main__":
    unittest.main()
