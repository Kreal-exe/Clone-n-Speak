"""Tests for Sources/cns_formant.py: formant shift and pitch shift."""
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
    import cns_formant as cf
    from audio_fixtures import SR, tone, voice, vowel, peak_freq, rms_db, write_wav


def formant_peaks(wav, sr=24000):
    """Peaks (Hz, 300..3000) of the cepstrally smoothed long-term spectrum (order 40)."""
    from scipy.signal import find_peaks
    n = 2048
    fr = np.lib.stride_tricks.sliding_window_view(np.asarray(wav, dtype=np.float64), n)[::512]
    mag = np.abs(np.fft.rfft(fr * np.hanning(n), axis=1)).mean(axis=0)
    cep = np.fft.irfft(np.log(mag + 1e-9))
    cep[41:-40] = 0
    env = np.fft.rfft(cep).real
    freqs = np.fft.rfftfreq(n, 1 / sr)
    pk, _ = find_peaks(env)
    return [float(freqs[i]) for i in pk if 300 <= freqs[i] <= 3000]


def nearest(peaks, target):
    return min(peaks, key=lambda f: abs(f - target))


def median_f0(x):
    f0 = core.track_f0(x, SR)
    return float(np.median(f0[f0 > 0]))


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class FormantTests(unittest.TestCase):
    def test_formant_identity(self):
        x = vowel(500, 1500)
        self.assertTrue(np.array_equal(cf.formant_shift(x, SR, 1.0), x))
        y = cf.formant_shift(x, SR, 1.0001)
        snr = 10 * np.log10((x.astype(np.float64) ** 2).sum() / (((y - x).astype(np.float64)) ** 2).sum())
        self.assertGreaterEqual(snr, 35)

    def test_formant_moves_envelope_not_pitch(self):
        x = vowel(500, 1500)
        y = cf.formant_shift(x, SR, 1.25)
        pk = formant_peaks(y)
        self.assertAlmostEqual(nearest(pk, 625), 625, delta=625 * 0.08)
        self.assertAlmostEqual(nearest(pk, 1875), 1875, delta=1875 * 0.08)
        self.assertAlmostEqual(median_f0(y), 120, delta=120 * 0.015)
        self.assertEqual(len(y), len(x))

    def test_formant_down(self):
        y = cf.formant_shift(vowel(500, 1500), SR, 0.8)
        self.assertAlmostEqual(nearest(formant_peaks(y), 400), 400, delta=32)

    def test_formant_clamps_and_survives_noise(self):
        x = vowel(500, 1500, seconds=0.5)
        self.assertTrue(np.array_equal(cf.formant_shift(x, SR, 5), cf.formant_shift(x, SR, 2.0)))
        self.assertTrue(np.array_equal(cf.formant_shift(x, SR, 0.01), cf.formant_shift(x, SR, 0.5)))
        noise = (0.1 * np.random.default_rng(0).standard_normal(SR * 2)).astype(np.float32)
        for r in (0.5, 2.0):
            y = cf.formant_shift(noise, SR, r)
            self.assertTrue(np.isfinite(y).all())
            self.assertLessEqual(abs(rms_db(y) - rms_db(noise)), 3)

    def test_stereo_and_short(self):
        x = vowel(500, 1500, seconds=0.5)
        st = np.stack([x, x * 0.5], axis=1)
        self.assertEqual(cf.formant_shift(st, SR, 1.2).shape, st.shape)
        self.assertEqual(cf.pitch_shift(st, SR, 3).shape, st.shape)
        self.assertEqual(len(cf.formant_shift(x[:100], SR, 1.2)), 100)
        self.assertEqual(len(cf.pitch_shift(x[:100], SR, 3)), 100)


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class PitchTests(unittest.TestCase):
    def test_pitch_shift_sine(self):
        x = tone(220, 2.0)
        y = cf.pitch_shift(x, SR, 12)
        self.assertAlmostEqual(peak_freq(y), 440, delta=4.4)
        self.assertLessEqual(abs(len(y) - len(x)), 0.01 * len(x))
        x = tone(330, 2.0)  # the brief says 220 Hz, but 220 * 2^(-5/12) = 164.8; 247.2 is 330 Hz down 5 st
        y = cf.pitch_shift(x, SR, -5)
        self.assertAlmostEqual(peak_freq(y), 247.2, delta=247.2 * 0.015)
        self.assertLessEqual(abs(len(y) - len(x)), 0.01 * len(x))
        self.assertTrue(np.array_equal(cf.pitch_shift(x, SR, 0), x))

    def test_pitch_shift_voice(self):
        x = voice(2)
        y = cf.pitch_shift(x, SR, 8)
        self.assertAlmostEqual(median_f0(y) / median_f0(x), 1.5874, delta=1.5874 * 0.02)

    def test_pitch_preserve_formants(self):
        x = vowel(500, 1500)
        plain = cf.pitch_shift(x, SR, 4)
        keep = cf.pitch_shift(x, SR, 4, preserve_formants=True)
        self.assertAlmostEqual(nearest(formant_peaks(plain), 630), 500 * 1.26, delta=63)
        self.assertAlmostEqual(nearest(formant_peaks(keep), 500), 500, delta=50)

    def test_registered_effects(self):
        for name in ("pitch", "formant"):
            self.assertIn(name, core.EFFECTS)
        try:
            import cns_fx
        except ImportError:
            return
        ids = [e["id"] for e in cns_fx.COMMANDS["fx_catalog"]({})["effects"]]
        self.assertIn("pitch", ids)
        self.assertIn("formant", ids)

    def test_commands(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "a.wav"), os.path.join(d, "b.wav")
            write_wav(src, vowel(500, 1500, seconds=1.0), SR)
            r = cf.COMMANDS["formant_apply"]({"audio": src, "out": out, "ratio": 1.2})
            self.assertAlmostEqual(r["seconds"], 1.0, places=2)
            y, _ = core.read_audio(out)
            self.assertTrue(np.isfinite(y).all() and np.abs(y).max() <= 1.0)
            r = cf.COMMANDS["pitch_apply"]({"audio": src, "out": out, "semitones": 3, "preserve_formants": 1})
            self.assertAlmostEqual(r["seconds"], 1.0, places=1)
            with self.assertRaises(core.AudioInputError):
                cf.COMMANDS["pitch_apply"]({"audio": src, "out": out, "semitones": "x"})


if __name__ == "__main__":
    unittest.main()
