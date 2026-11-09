"""Tests for Sources/cns_analyze.py: waveform, spectrogram, pitch and centroid data."""
import os
import pathlib
import sys
import tempfile
import time
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
    import cns_analyze as an
    import cns_core as core
    from audio_fixtures import SR, voice, write_wav


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class AnalyzeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def run_an(self, wav, sr, subtype="float32", **kw):
        src = os.path.join(self.dir, "in.wav")
        write_wav(src, wav, sr, subtype)
        req = {"cmd": "analyze_audio", "audio": src, "out_dir": os.path.join(self.dir, "out")}
        req.update(kw)
        return an.COMMANDS["analyze_audio"](req)

    @staticmethod
    def matrix(r):
        sp = r["spectrogram"]
        data = np.fromfile(sp["path"], dtype=np.uint8)
        return data.reshape(sp["rows"], sp["cols"])

    @staticmethod
    def chirp(sr, seconds=2.0, f0=200.0, f1=4000.0):
        t = np.arange(int(sr * seconds)) / sr
        return (0.3 * np.sin(2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * seconds)))).astype(np.float32)

    def ridge(self, r):
        return self.matrix(r).argmax(axis=0)

    def test_chirp_ridge(self):
        r = self.run_an(self.chirp(SR), SR)
        ridge = self.ridge(r)
        sp = r["spectrogram"]
        col = int(round(1.0 / sp["col_s"]))
        self.assertAlmostEqual(sp["row_hz"][ridge[col]], 2100.0, delta=2100 * 0.06)
        lo, hi = int(0.1 / sp["col_s"]), int(1.9 / sp["col_s"])
        c = np.corrcoef(np.arange(lo, hi), ridge[lo:hi])[0, 1]
        self.assertGreaterEqual(c, 0.98)

    def test_f0_of_buzz(self):
        r = self.run_an(voice(2, f0=150), SR)
        self.assertAlmostEqual(r["f0"]["median_hz"], 150, delta=150 * 0.03)
        v = np.array(r["f0"]["values"])
        self.assertGreater(int((v > 0).sum()), 0.8 * len(v))
        x = voice(3, f0=150)  # a pause in the middle is unvoiced
        x[SR:2 * SR] = 0
        v = np.array(self.run_an(x, SR)["f0"]["values"])
        mid = v[int(len(v) * 0.4):int(len(v) * 0.6)]
        self.assertTrue((mid == 0).all())

    def test_centroid_order(self):
        t = np.arange(SR * 2) / SR
        sine = (0.3 * np.sin(2 * np.pi * 1000 * t)).astype(np.float32)
        noise = (0.2 * np.random.default_rng(1).standard_normal(SR * 2)).astype(np.float32)
        rs, rn = self.run_an(sine, SR), self.run_an(noise, SR)
        cs = float(np.median(rs["centroid"]["values_hz"]))
        cn = float(np.median(rn["centroid"]["values_hz"]))
        self.assertLess(cs, cn)
        self.assertAlmostEqual(cs, 1000, delta=150)
        fmax = rn["spectrogram"]["fmax"]
        self.assertAlmostEqual(cn, fmax / 2, delta=fmax / 2 * 0.15)

    def test_silence(self):
        r = self.run_an(np.zeros(SR * 3, dtype=np.float32), SR)
        self.assertFalse(self.matrix(r).any())
        self.assertIsNone(r["f0"]["median_hz"])
        self.assertTrue(all(p == [0, 0] for p in r["waveform"]["peaks"]))
        self.assertTrue(np.isfinite(r["f0"]["values"]).all())
        self.assertTrue(np.isfinite(r["centroid"]["values_hz"]).all())
        self.assertTrue(np.isfinite([r["rms_db"], r["peak"]]).all())

    def test_shapes_and_limits(self):
        r = self.run_an(voice(3), SR, cols=1200)
        sp = r["spectrogram"]
        self.assertEqual(os.path.getsize(sp["path"]), sp["cols"] * sp["rows"])
        self.assertEqual((sp["cols"], sp["rows"]), (1200, 256))
        self.assertLessEqual(len(r["waveform"]["peaks"]), 2000)
        self.assertEqual(len(sp["row_hz"]), sp["rows"])
        self.assertLessEqual(len(r["f0"]["values"]), sp["cols"])
        self.assertLessEqual(len(r["centroid"]["values_hz"]), sp["cols"])
        self.assertTrue(all(-1 <= a <= b <= 1 for a, b in r["waveform"]["peaks"]))
        r = self.run_an(voice(1), SR, cols=200, rows=64)
        self.assertEqual(os.path.getsize(r["spectrogram"]["path"]), 200 * 64)
        for bad in ({"cols": 100}, {"cols": 2001}, {"rows": 63}, {"rows": 385}):
            with self.assertRaises(core.AudioInputError) as cm:
                self.run_an(voice(1), SR, **bad)
            self.assertEqual(cm.exception.code, "bad_param")

    def test_stereo_and_rates(self):
        ridge0 = self.ridge(self.run_an(self.chirp(SR), SR))
        c = self.chirp(96000)
        r = self.run_an(np.stack([c, c], axis=1), 96000)
        self.assertEqual((r["sr"], r["channels"]), (96000, 2))
        self.assertEqual(r["spectrogram"]["fmax"], 8000.0)
        ridge1 = self.ridge(r)
        lo, hi = 20, 1100
        self.assertLessEqual(int(np.abs(ridge1[lo:hi] - ridge0[lo:hi]).max()), 1)
        mono = self.run_an(c, 96000)
        self.assertLessEqual(int(np.abs(self.ridge(mono)[lo:hi] - ridge1[lo:hi]).max()), 1)

    def test_long_file_speed(self):
        x = (0.2 * np.random.default_rng(2).standard_normal(16000 * 600)).astype(np.float32)
        t0 = time.time()
        r = self.run_an(x, 16000)
        self.assertLess(time.time() - t0, 30)
        self.assertEqual(r["seconds"], 600.0)

    def test_out_dir_confined(self):
        sub = os.path.join(self.dir, "a", "..", "b", "c")
        r = self.run_an(voice(1), SR, out_dir=sub)
        target = os.path.join(self.dir, "b", "c")
        self.assertEqual(r["spectrogram"]["path"], os.path.join(target, "spectrogram.u8"))
        self.assertEqual(sorted(os.listdir(target)), ["spectrogram.u8"])
        self.assertEqual(sorted(os.listdir(self.dir)), ["b", "in.wav"])


if __name__ == "__main__":
    unittest.main()
