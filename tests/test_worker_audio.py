"""Unit tests for the audio helpers in Sources/worker.py (pitch, melody, tone, trimming).

Run: python3 -m unittest discover -s tests      (needs: pip install numpy scipy; skipped without them)
"""
import importlib.util
import pathlib
import sys
import unittest

try:
    import numpy as np
    import scipy  # noqa: F401
except ImportError:
    np = None

_path = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "worker.py"
_spec = importlib.util.spec_from_file_location("worker_audio", _path)
worker = importlib.util.module_from_spec(_spec)
_stdout = sys.stdout
_spec.loader.exec_module(worker)  # the worker redirects stdout to stderr on import
sys.stdout = _stdout

SR = worker.SR


def voice(seconds, f0=120.0, vibrato=0.0):
    """A buzzy, voice-like tone: harmonics of f0, optionally gliding ±`vibrato` semitones twice a second."""
    t = np.arange(int(SR * seconds)) / SR
    freq = f0 * 2 ** (vibrato * np.sin(2 * np.pi * 2 * t) / 12)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    return (0.1 * sum(np.sin(k * phase) / k for k in range(1, 9))).astype(np.float32)


def pitch_range(wav):
    f0 = worker.track_f0(wav)
    f0 = f0[f0 > 0]
    return 12 * np.log2(np.percentile(f0, 95) / np.percentile(f0, 5))


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class Audio(unittest.TestCase):
    def test_pitch_tracker(self):
        f0 = worker.track_f0(voice(1.0, 150))
        self.assertAlmostEqual(float(np.median(f0[f0 > 0])), 150, delta=2)
        self.assertEqual(int((worker.track_f0(np.zeros(SR, dtype=np.float32)) > 0).sum()), 0)

    def test_change_pitch_moves_pitch_and_length(self):
        wav = voice(1.0, 120)
        up = worker.change_pitch(wav, 3)
        f0 = worker.track_f0(up)
        self.assertAlmostEqual(float(np.median(f0[f0 > 0])), 120 * 2 ** (3 / 12), delta=3)
        self.assertAlmostEqual(len(up) / len(wav), 2 ** (-3 / 12), delta=0.01)
        self.assertIs(worker.change_pitch(wav, 0), wav)

    def test_melody_is_widened_and_narrowed(self):
        wav = voice(2.0, 120, vibrato=2.0)
        base = pitch_range(wav)
        self.assertGreater(pitch_range(worker.scale_melody(wav, 1.6)), base * 1.25)
        self.assertLess(pitch_range(worker.scale_melody(wav, 0.4)), base * 0.6)
        self.assertIs(worker.scale_melody(wav, 1.0), wav)
        silence = np.zeros(SR, dtype=np.float32)
        self.assertIs(worker.scale_melody(silence, 1.6), silence)  # nothing voiced: left alone

    def test_tone_tilts_the_spectrum_and_keeps_loudness(self):
        rng = np.random.default_rng(1)
        noise = (0.05 * rng.standard_normal(SR * 2)).astype(np.float32)

        def bands(x):
            spec = np.abs(np.fft.rfft(x)) ** 2
            freq = np.fft.rfftfreq(len(x), 1 / SR)
            return spec[freq < 150].sum(), spec[freq > 6000].sum()
        low0, high0 = bands(noise)
        for tone, brighter in ((1.0, True), (-1.0, False)):
            out = worker.shape_voice(noise, dict(worker.resolve_style({"tone": tone})))
            low, high = bands(out)
            self.assertEqual(high / low > high0 / low0, brighter)
            self.assertAlmostEqual(float(np.sqrt((out ** 2).mean())), float(np.sqrt((noise ** 2).mean())), delta=0.002)

    def test_volume_and_limiter(self):
        wav = voice(1.0)
        loud = worker.shape_voice(wav, worker.resolve_style({"volume": 12}))
        self.assertGreater(float(np.sqrt((loud ** 2).mean())), 2 * float(np.sqrt((wav ** 2).mean())))
        self.assertLessEqual(float(np.abs(loud).max()), 0.97)
        same = worker.shape_voice(wav, worker.resolve_style(None))
        self.assertTrue(np.allclose(same, wav, atol=1e-6))

    def test_long_sample_is_cut_at_a_pause(self):
        speech, pause = voice(4.0), np.zeros(int(SR * 0.5), dtype=np.float32)
        wav = np.concatenate([pause, speech, pause, speech, pause, speech, pause, speech])  # 4.5 s per phrase
        cut = worker.trim_sample(wav)
        self.assertAlmostEqual(len(cut) / SR, 8.75, delta=0.3)  # two phrases, cut inside the second pause
        endless = worker.trim_sample(voice(40.0))
        self.assertAlmostEqual(len(endless) / SR, 10.0, delta=0.3)  # no pause: the target length


if __name__ == "__main__":
    unittest.main()
