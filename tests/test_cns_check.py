"""Tests for Sources/cns_check.py: extended sample check and comparison of samples."""
import os
import pathlib
import sys
import tempfile
import unittest

try:
    import numpy as np
    import scipy  # noqa: F401
except ImportError:
    np = None

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))
sys.path.insert(0, str(HERE))

if np is not None:
    import cns_core as core
    import cns_check
    from audio_fixtures import SR, speechlike, voice, write_wav


def overlap(r, a, b):
    return max(0.0, min(r["end"], b) - max(r["start"], a))


def mains_hum(hz, seconds, db=-35):
    t = np.arange(int(SR * seconds)) / SR
    h = sum(np.sin(2 * np.pi * hz * k * t) / k for k in (1, 2, 3))
    return (h / np.sqrt((h ** 2).mean()) * 10 ** (db / 20)).astype(np.float32)


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name, wav, sr=24000):
        p = os.path.join(self.tmp.name, name)
        write_wav(p, wav, sr)
        return p

    def check(self, wav, sr=24000, name="a.wav"):
        return cns_check.cmd_sample_check({"audio": self.path(name, wav, sr)})

    def test_same_keys_as_old_analyze(self):
        p = self.path("v.wav", voice(5))
        got = cns_check.cmd_sample_check({"audio": p})
        old = core.quality_report(core.read_audio(p, sr=SR)[0], SR)
        for k, v in old.items():
            self.assertEqual(got[k], v, k)
        for k in ("lead_silence_s", "tail_silence_s", "longest_pause", "regions", "hum_hz", "advice"):
            self.assertIn(k, got)

    def test_edges(self):
        z = np.zeros
        wav = np.concatenate([z(int(SR * 0.8)), speechlike(2.8), z(int(SR * 0.5))]).astype(np.float32)
        r = self.check(wav)
        self.assertAlmostEqual(r["lead_silence_s"], 0.8, delta=0.06)
        self.assertAlmostEqual(r["tail_silence_s"], 0.5, delta=0.06)
        self.assertIn("trim_start", r["advice"])
        self.assertIn("trim_end", r["advice"])

    def test_longest_pause(self):
        wav = np.concatenate([speechlike(2.8), np.zeros(int(SR * 2.0), np.float32), speechlike(2.8)])
        r = self.check(wav)
        lp = r["longest_pause"]
        self.assertAlmostEqual(lp["seconds"], 2.0, delta=0.1)
        self.assertAlmostEqual(lp["start"], 2.8, delta=0.1)
        self.assertTrue(any(g["kind"] == "pause" and overlap(g, 2.8, 4.8) > 1.8 for g in r["regions"]))
        self.assertIn("long_pause", r["advice"])

    def test_short_pause_is_not_longest(self):
        wav = np.concatenate([speechlike(2.0), np.zeros(int(SR * 0.4), np.float32), speechlike(2.0)])
        self.assertIsNone(self.check(wav)["longest_pause"])

    def test_edge_debounce(self):
        z = lambda s: np.zeros(int(SR * s), np.float32)  # noqa: E731
        noise = lambda s: (10 ** (-58 / 20) * np.random.default_rng(5).standard_normal(int(SR * s))).astype(np.float32)  # noqa: E731
        lead = z(1.0)
        a = int(SR * 0.4)
        lead[a:a + int(SR * 0.01)] = 0.5  # one click inside the lead silence
        wav = np.concatenate([lead, speechlike(2.8), noise(0.6)])
        r = self.check(wav)
        self.assertAlmostEqual(r["lead_silence_s"], 1.0, delta=0.08)
        self.assertAlmostEqual(r["tail_silence_s"], 0.6, delta=0.08)

    def test_clipping_region(self):
        wav = speechlike(3.0).copy()
        a = int(SR * 1.2)
        wav[a:a + int(SR * 0.1)] = 1.0
        r = self.check(wav)
        self.assertTrue(any(g["kind"] == "clipping" and overlap(g, 1.2, 1.3) > 0.09 for g in r["regions"]))
        self.assertIn("clipping", r["issues"])

    def test_noise_burst_region(self):
        z = lambda s: np.zeros(int(SR * s), np.float32)  # noqa: E731
        wav = np.concatenate([speechlike(1.8), z(0.2), z(0.5), z(0.5), speechlike(1.5)])
        a = int(SR * 2.0)
        burst = np.random.default_rng(3).standard_normal(int(SR * 0.5))
        wav[a:a + len(burst)] = (10 ** (-25 / 20) * burst).astype(np.float32)
        r = self.check(wav)
        best = max([overlap(g, 2.0, 2.5) for g in r["regions"] if g["kind"] == "noise"] or [0])
        self.assertGreaterEqual(best, 0.8 * 0.5)

    def test_hum(self):
        speech = speechlike(4.0)
        self.assertEqual(self.check(speech + mains_hum(50, 4.0))["hum_hz"], 50)
        self.assertIsNone(self.check(speech, name="clean.wav")["hum_hz"])
        self.assertIsNone(self.check(voice(5), name="v.wav")["hum_hz"])
        r = self.check(speech + mains_hum(60, 4.0), name="h60.wav")
        self.assertEqual(r["hum_hz"], 60)
        self.assertIn("hum", r["advice"])
        self.assertTrue(any(g["kind"] == "hum" for g in r["regions"]))

    def test_compare_duplicate_and_levels(self):
        a = np.concatenate([speechlike(4.0), voice(1.0) * 0.3, speechlike(5.0)[::-1].copy()])
        a = (a * (0.3 / np.abs(a).max())).astype(np.float32)
        b = (a[int(SR * 1.3):] * 0.501).astype(np.float32)
        rng = np.random.default_rng(5)
        mod = np.abs(np.sin(2 * np.pi * 0.7 * np.arange(len(a)) / SR))
        c = (0.3 * mod * rng.standard_normal(len(a))).astype(np.float32).clip(-1, 1)
        d = (a * 0.1).astype(np.float32)
        paths = [self.path(n + ".wav", w) for n, w in zip("abcd", (a, b, c, d))]
        r = cns_check.cmd_compare_samples({"audios": paths})
        self.assertEqual(len(r["samples"]), 4)
        pair = {(p["a"], p["b"]): p for p in r["pairs"]}
        self.assertTrue(pair[(0, 1)]["duplicate"])
        self.assertAlmostEqual(pair[(0, 1)]["level_diff_db"], 6.0, delta=0.7)
        self.assertFalse(pair[(0, 2)]["duplicate"])
        self.assertFalse(pair[(1, 2)]["duplicate"])
        self.assertIn(3, r["outliers"])
        self.assertNotIn(1, r["outliers"])
        self.assertIn("median_rms_db", r)

    def test_silence_and_short(self):
        r = self.check(np.zeros(SR * 3, np.float32))
        self.assertIn("quiet", r["issues"])
        self.assertLessEqual(r["score"], 20)
        r = self.check(voice(0.3), name="s.wav")
        self.assertIn("short", r["issues"])
        p = self.path("long.wav", np.zeros(8000 * 1800, np.float32), 8000)
        with self.assertRaises(core.AudioInputError) as cm:
            cns_check.cmd_sample_check({"audio": p})
        self.assertEqual(cm.exception.code, "too_long")

    def test_compare_limits(self):
        with self.assertRaises(core.AudioInputError) as cm:
            cns_check.cmd_compare_samples({"audios": ["x%d.wav" % i for i in range(13)]})
        self.assertEqual(cm.exception.code, "bad_param")
        with self.assertRaises(core.AudioInputError):
            cns_check.cmd_compare_samples({"audios": []})

    def test_registered(self):
        self.assertIn("sample_check", core.TOOLS)
        self.assertEqual(set(cns_check.COMMANDS), {"sample_check", "compare_samples"})


if __name__ == "__main__":
    unittest.main()
