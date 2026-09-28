"""Unit tests of templates/count_alt_by_cycle.py: cycles in sequencing orientation (python3 -m unittest discover -s <dir>)."""
import pathlib
import re
import types
import unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "templates" / "count_alt_by_cycle.py"
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def load():
    src = TEMPLATE.read_text()
    mod = types.ModuleType("count_alt_by_cycle")
    exec(compile(PLACEHOLDER.sub("", src), str(TEMPLATE), "exec"), mod.__dict__)
    return mod


M = load()
SITES = {103: ("A", "G"), 110: ("C", "T")}
Q = "I" * 10                              # Q40


class TemplateHygiene(unittest.TestCase):
    def test_no_backslash_or_dollar_outside_placeholders(self):
        src = TEMPLATE.read_text()
        self.assertNotIn("\\", src)
        self.assertNotIn("$", PLACEHOLDER.sub("", src))
        main_at = src.index("def main():")
        self.assertTrue(all(m.start() > main_at for m in PLACEHOLDER.finditer(src)))


class Cycles(unittest.TestCase):
    def test_forward_r1(self):
        # 10M at 101: site 103 is read index 2 -> cycle 3; base G = ALT
        self.assertEqual(M.record_bases(0x41, 101, "10M", "AAGAAAAAAC", Q, SITES, 20), [(1, 3, 2), (1, 10, 1)])

    def test_reverse_r2(self):
        # reverse: cycle = length - index; site 103 (index 2) -> cycle 8, site 110 (index 9) -> cycle 1; T = ALT
        self.assertEqual(M.record_bases(0x91, 101, "10M", "AAAAAAAAAT", Q, SITES, 20), [(2, 8, 1), (2, 1, 2)])

    def test_soft_and_hard_clips_counted(self):
        # 2H3S5M at 101: aligned bases are read indices 3..7 (+2 hard) -> site 103 at SEQ index 5, original index 7
        got = M.record_bases(0x41, 101, "2H3S5M", "NNNAAGAA", "I" * 8, SITES, 20)
        self.assertEqual(got, [(1, 8, 2)])

    def test_deletion_and_low_quality(self):
        # 2M1D7M at 101: 101, 102, (103 deleted), 104..110 -> site 103 not observed; 110 at SEQ index 8
        self.assertEqual(M.record_bases(0x41, 101, "2M1D7M", "AAAAAAAAC", "I" * 9, SITES, 20), [(1, 9, 1)])
        self.assertEqual(M.record_bases(0x41, 101, "10M", "AAGAAAAAAC", "II!IIIIIII", SITES, 20), [(1, 10, 1)])

    def test_other_class_and_bins(self):
        self.assertEqual(M.record_bases(0x41, 101, "10M", "AATAAAAAAC", Q, SITES, 20)[0], (1, 3, 3))
        bins = M.parse_bins(M.DEFAULT_BINS)
        self.assertEqual(M.bin_of(1, bins), "1-2")
        self.assertEqual(M.bin_of(12, bins), "9-12")
        self.assertEqual(M.bin_of(150, bins), "81-")


if __name__ == "__main__":
    unittest.main()
