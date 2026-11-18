"""Resources/bridge-pin.json: the one pinned address and checksums of the Bridge helper (cloudflared)."""
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PIN = ROOT / "Resources" / "bridge-pin.json"
URL_TEMPLATE = "https://github.com/cloudflare/cloudflared/releases/download/%s/cloudflared-darwin-arm64.tgz"


class BridgePin(unittest.TestCase):
    def setUp(self):
        self.pin = json.loads(PIN.read_text())

    def test_pin_shape(self):
        self.assertEqual(set(self.pin), {"version", "url", "sha256_archive", "sha256_binary", "team_id"})
        self.assertRegex(self.pin["version"], r"^\d{4}\.\d+\.\d+$")
        self.assertEqual(self.pin["url"], URL_TEMPLATE % self.pin["version"])
        for k in ("sha256_archive", "sha256_binary"):
            self.assertRegex(self.pin[k], r"^[0-9a-f]{64}$", k)
        self.assertNotEqual(self.pin["sha256_archive"], self.pin["sha256_binary"])
        self.assertRegex(self.pin["team_id"], r"^[A-Z0-9]{10}$")

    def test_pin_is_copied_into_the_app(self):
        self.assertIn("bridge-pin.json", (ROOT / "build.sh").read_text())


if __name__ == "__main__":
    unittest.main()
