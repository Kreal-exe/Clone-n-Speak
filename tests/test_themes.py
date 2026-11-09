import json
import re
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "Resources" / "themes.json"
ROLES = ["background", "surface", "field", "border", "text", "muted", "accent", "accentSoft",
         "cta", "ctaText", "ghostBorder", "log", "ok", "warn", "err", "focus"]
ORDER = ["applio", "amethyst", "crimson", "cyberpunk", "emerald", "midnight", "sunset", "halloween"]
HEX = re.compile(r"^#[0-9a-f]{6}([0-9a-f]{2})?$")


def load():
    return {p["id"]: p for p in json.loads(PATH.read_text())["palettes"]}


def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


class ThemeTests(unittest.TestCase):
    def test_all_palettes_have_all_roles(self):
        for pid, p in load().items():
            for mode in ("dark", "light"):
                self.assertEqual(sorted(p[mode]), sorted(ROLES), f"{pid}/{mode}")
                for r, v in p[mode].items():
                    self.assertRegex(v, HEX, f"{pid}/{mode}/{r}")

    def test_palette_order(self):
        data = json.loads(PATH.read_text())["palettes"]
        self.assertEqual([p["id"] for p in data], ORDER)
        self.assertTrue(all(p["title"] for p in data))

    def test_applio_dark_tokens(self):
        want = dict(background="#110f0f", surface="#262626", border="#ffffff17", field="#171717", text="#ffffff", muted="#a3a3a3",
                    accentSoft="#404040", cta="#525252", ctaText="#ffffff", log="#0a0a0a", ok="#4ade80",
                    warn="#fbbf24", err="#f87171", focus="#3b82f6")
        d = load()["applio"]["dark"]
        for k, v in want.items():
            self.assertEqual(d[k], v, k)

    def test_applio_light_tokens(self):
        want = dict(background="#fafafa", surface="#ffffff", field="#f4f4f5", border="#e4e4e7", text="#09090b",
                    muted="#71717a", cta="#18181b", ctaText="#ffffff", focus="#2563eb")
        d = load()["applio"]["light"]
        for k, v in want.items():
            self.assertEqual(d[k], v, k)

    def test_palette_contrast(self):
        for pid, p in load().items():
            for mode in ("dark", "light"):
                d = p[mode]
                for a, b, lim in (("text", "surface", 4.5), ("text", "background", 4.5), ("ctaText", "cta", 4.5),
                                  ("muted", "surface", 4.5), ("focus", "surface", 3.0)):
                    self.assertGreaterEqual(contrast(d[a][:7], d[b][:7]), lim, f"{pid}/{mode} {a} on {b}")


if __name__ == "__main__":
    unittest.main()
