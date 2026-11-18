"""The ObjC model table of the stems card (Sources/OVStemsCard.m) must agree with cns_stems_catalog."""
import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Sources"))
import cns_stems_catalog as cat  # noqa: E402

ROW = re.compile(r'\[self id:@"([^"]+)" title:L\(@"[^"]+"\) kind:\w+ license:@"([^"]+)" verified:(YES|NO) peak:([\d.]+)')


class StemsCardTable(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, "Sources", "OVStemsCard.m"), encoding="utf-8") as f:
            self.rows = {m[0]: m for m in ROW.findall(f.read())}

    def test_ids_match_the_catalog(self):
        self.assertEqual(set(self.rows), {e["id"] for e in cat.CATALOG})

    def test_license_and_verified_match(self):
        for e in cat.CATALOG:
            _, lic, verified, _ = self.rows[e["id"]]
            self.assertEqual(verified == "YES", e["verified"], e["id"])
            self.assertEqual(lic, e["license"], e["id"])

    def test_peak_is_not_below_the_catalog(self):
        for e in cat.CATALOG:
            self.assertGreaterEqual(float(self.rows[e["id"]][3]), e["peak_gb"], e["id"])


if __name__ == "__main__":
    unittest.main()
