"""Tests for Sources/cns_presets.py."""
import json
import pathlib
import sys
import unittest

SOURCES = pathlib.Path(__file__).resolve().parent.parent / "Sources"
sys.path.insert(0, str(SOURCES))

import cns_core as core  # noqa: E402
import cns_presets as presets  # noqa: E402


def setUpModule():
    if "t_gain" not in core.EFFECTS:
        core.register_effect("t_gain", lambda w, sr, **p: w, {
            "gain_db": {"min": -24, "max": 24, "default": 0, "unit": "dB", "title": "Gain"},
            "mode": {"choices": ["a", "b"], "default": "a", "title": "Mode"}})


def base(**kw):
    p = {"version": 1, "name": "Warm", "style": {"pace": 1.0, "mood": "calm"},
         "format": {"id": "flac", "quality": None},
         "chain": [{"type": "t_gain", "on": True, "params": {"gain_db": 3, "mode": "b"}}], "formant": 1.1}
    p.update(kw)
    return p


class PresetTests(unittest.TestCase):
    def test_roundtrip(self):
        p, w = presets.validate_preset(base())
        self.assertEqual(w, [])
        text = presets.export_preset(p)
        self.assertEqual(text, presets.export_preset(p))
        self.assertTrue(text.endswith("}\n"))
        self.assertEqual(presets.validate_preset(json.loads(text))[0], p)

    def test_clamps_and_warnings(self):
        d = base(evil=1, chain=[{"type": "t_gain", "on": True, "params": {"gain_db": 99}}, {"type": "nope"}])
        p, w = presets.validate_preset(d)
        self.assertEqual(p["chain"][0]["params"]["gain_db"], 24)
        self.assertEqual(len(p["chain"]), 1)
        self.assertNotIn("evil", p)
        self.assertTrue(any("gain_db" in x for x in w))
        self.assertTrue(any("nope" in x for x in w))

    def test_rejects(self):
        for bad in (base(version=2), [1], base(name=""), base(name="x" * 61), base(style={"k": "y" * 70000})):
            with self.assertRaises(ValueError) as c:
                presets.validate_preset(bad)
            self.assertGreater(len(str(c.exception)), 20)
        self.assertIn("newer version", str(self._err(base(version=2))))
        for junk in ("\x00\x01\xff garbage", b"\xff\xfe\x00\x80", "x" * 70000):
            with self.assertRaises(ValueError):
                presets.COMMANDS["preset_validate"]({"json": junk})

    def _err(self, d):
        try:
            presets.validate_preset(d)
        except ValueError as e:
            return e

    def test_format_ids(self):
        p, w = presets.validate_preset(base(format={"id": "exe", "quality": 3}))
        self.assertEqual(p["format"], {"id": "wav", "quality": 3})
        self.assertTrue(w)

    def test_formant_range(self):
        self.assertEqual(presets.validate_preset(base(formant=9))[0]["formant"], 2.0)
        self.assertEqual(presets.validate_preset(base(formant=0.1))[0]["formant"], 0.5)
        d = base()
        del d["formant"]
        self.assertNotIn("formant", presets.validate_preset(d)[0])

    def test_command(self):
        r = presets.COMMANDS["preset_validate"]({"json": json.dumps(base(formant=3))})
        self.assertEqual(r["preset"]["formant"], 2.0)
        self.assertTrue(r["warnings"])


if __name__ == "__main__":
    unittest.main()
