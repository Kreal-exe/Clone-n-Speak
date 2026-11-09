"""Tests for Sources/cns_fx.py: the effects chain. Effects are called through core.EFFECTS (the raw effect, without
the chain's safety limiter) or apply_chain (the whole chain)."""
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

SR = 24000
if np is not None:
    import cns_core as core
    import cns_fx as fx
    from audio_fixtures import tone, voice, write_wav, rms_db


def run(name, wav, **params):
    return core.EFFECTS[name]["fn"](wav, SR, **params)


def chain(*items):
    return [{"type": n, "params": p} for n, p in items]


def peak_db(x):
    return 20 * np.log10(float(np.abs(x).max()) + 1e-12)


def schroeder_rt(h, sr=SR):
    """Reverb time from the T20 range (-5 to -25 dB) of the backward-integrated energy, extrapolated to -60."""
    e = np.cumsum((h.astype(np.float64) ** 2)[::-1])[::-1]
    d = 10 * np.log10(e / e[0] + 1e-30)
    i5, i25 = int(np.argmax(d <= -5)), int(np.argmax(d <= -25))
    return 3.0 * (i25 - i5) / sr


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class FxTests(unittest.TestCase):
    def test_gain(self):
        x = tone(440, 1.0)
        y = run("gain", x, gain_db=6.0206)
        self.assertAlmostEqual(np.sqrt((y ** 2).mean()) / np.sqrt((x ** 2).mean()), 2.0, delta=0.01)
        self.assertLess(float(np.abs(run("gain", x, gain_db=0) - x).max()), 1e-7)

    def test_eq_peak_and_shelf(self):
        def gain_db(f, **p):
            x = tone(f, 2.0)
            y = run("eq", x, **p)
            return rms_db(y[SR:]) - rms_db(x[SR:])
        peak = dict(low_db=0, mid_db=9, high_db=0, low_hz=120, mid_hz=1000, high_hz=6000)
        self.assertAlmostEqual(gain_db(1000, **peak), 9, delta=0.5)
        self.assertLess(abs(gain_db(100, **peak)), 0.5)
        shelf = dict(low_db=-6, mid_db=0, high_db=0, low_hz=120, mid_hz=1000, high_hz=6000)
        self.assertAlmostEqual(gain_db(60, **shelf), -6, delta=1)

    def test_compressor(self):
        base = dict(threshold_db=-20, ratio=4, attack_ms=1, release_ms=50, makeup_db=0)
        loud = tone(1000, 2.0, amp=10 ** (-10 / 20))
        self.assertAlmostEqual(peak_db(run("compressor", loud, **base)[-SR // 2:]), -17.5, delta=0.7)
        quiet = tone(1000, 2.0, amp=10 ** (-30 / 20))
        self.assertAlmostEqual(peak_db(run("compressor", quiet, **base)[-SR // 2:]), -30, delta=0.2)
        made = run("compressor", quiet, **dict(base, makeup_db=6))
        self.assertAlmostEqual(peak_db(made[-SR // 2:]), -24, delta=0.3)

    def test_limiter_ceiling(self):
        noise = np.random.default_rng(0).standard_normal(3 * SR)
        noise = (noise / np.abs(noise).max()).astype(np.float32)
        quiet = (10 ** (-30 / 20) * tone(300, 1.0, amp=1.0))
        x = np.concatenate([noise, np.zeros(SR // 2, dtype=np.float32), quiet])
        y = run("limiter", x, ceiling_db=-6, release_ms=80, lookahead_ms=5)
        self.assertLessEqual(float(np.abs(y).max()), 0.5012)
        self.assertEqual(len(y), len(x))
        self.assertAlmostEqual(rms_db(y[-SR // 2:]), rms_db(x[-SR // 2:]), delta=0.1)

    def test_distortion(self):
        x = tone(440, 1.0, amp=0.3)
        y = run("distortion", x, drive_db=24, tone=0.5, mix=1)  # unity gain at 0 dB: a little more drive
        spec = np.abs(np.fft.rfft(y[:SR])) ** 2  # 1 s: bin k is k Hz
        harmonics = sum(spec[440 * k] for k in range(2, 6))
        self.assertGreaterEqual(harmonics / spec[440], 0.1)
        self.assertLess(float(np.abs(run("distortion", x, drive_db=0, tone=0.5, mix=0) - x).max()), 1e-7)

    def test_bitcrush(self):
        x = voice(1.0)
        loud = (x / np.abs(x).max()).astype(np.float32)  # reaches full scale: the 4-bit range must still be 16 values
        self.assertLessEqual(len(np.unique(run("bitcrush", loud, bits=4, downsample=1, mix=1))), 16)
        y = run("bitcrush", x, bits=16, downsample=4, mix=1)
        i = np.arange(len(y))
        self.assertTrue(np.array_equal(y, y[4 * (i // 4)]))
        self.assertLess(float(np.abs(run("bitcrush", x, bits=16, downsample=1, mix=1) - x).max()), 1e-4)

    def test_bitcrush_symmetric(self):
        x = tone(440, 1.0, amp=0.3)
        for bits in (1, 2, 3):
            y = run("bitcrush", x, bits=bits, downsample=1, mix=1)
            self.assertGreater(float(np.abs(y).max()), 0.1, bits)
            self.assertLess(abs(float(y.mean())), 0.01, bits)

    def test_distortion_unity_gain(self):
        x = tone(200, 1.0, amp=0.01)
        y = run("distortion", x, drive_db=0, tone=1.0, mix=1)
        self.assertAlmostEqual(rms_db(y[SR // 4:]), rms_db(x[SR // 4:]), delta=0.5)

    def test_fx_apply_needs_audio(self):
        with self.assertRaises(core.AudioInputError) as c:
            fx.fx_apply({"out": "/tmp/x.wav", "chain": []})
        self.assertEqual(c.exception.code, "bad_param")

    def test_delay_exact(self):
        x = np.zeros(SR, dtype=np.float32)
        x[0] = 1.0
        y = run("delay", x, time_ms=250, feedback=0.5, mix=0.5)
        for i, want in ((0, 1.0), (6000, 0.5), (12000, 0.25), (18000, 0.125)):
            self.assertAlmostEqual(float(y[i]), want, delta=1e-4)
        mask = np.ones(len(y), dtype=bool)
        mask[[0, 6000, 12000, 18000]] = False
        self.assertLess(float(np.abs(y[mask]).max()), 1e-6)

    def test_chorus(self):
        x = tone(440, 2.0)
        y = run("chorus", x, rate_hz=1, depth_ms=3, mix=0.5)
        self.assertEqual(len(y), len(x))
        ratio = np.sqrt((y ** 2).mean() / (x ** 2).mean())
        self.assertTrue(0.7 <= ratio <= 1.0, ratio)
        self.assertGreater(float(np.abs(y - x).max()), 0.05)
        self.assertLess(float(np.abs(run("chorus", x, rate_hz=1, depth_ms=3, mix=0) - x).max()), 1e-7)

    def test_reverb_tail(self):
        x = np.zeros(8 * SR, dtype=np.float32)
        x[0] = 1.0
        big = run("reverb", x, room=0.9, damping=0.5, predelay_ms=10, mix=1, tail_s=4)
        small = run("reverb", x, room=0.3, damping=0.5, predelay_ms=10, mix=1, tail_s=4)
        rt_big, rt_small = schroeder_rt(big), schroeder_rt(small)
        self.assertGreaterEqual(rt_big, 2 * rt_small, (rt_big, rt_small))
        self.assertTrue(1.2 <= rt_big <= 6, rt_big)
        self.assertLess(float(np.abs(run("reverb", x, room=0.9, damping=0.5, predelay_ms=10, mix=0, tail_s=4) - x).max()), 1e-7)
        quarter = len(big) // 4
        self.assertLess((big[-quarter:] ** 2).sum(), (big[:quarter] ** 2).sum())
        v = voice(1.0)
        params = {"type": "reverb", "params": {"room": 0.5, "mix": 0.4, "tail_s": 2.0}}
        self.assertEqual(len(fx.apply_chain(v, SR, [params], extend=True)), len(v) + int(round(1.0 * SR)))
        self.assertEqual(len(fx.apply_chain(v, SR, [params], extend=False)), len(v))

    def test_chain_order_off_unknown_clamp(self):
        x = tone(440, 1.0, amp=0.5)
        a = fx.apply_chain(x, SR, chain(("distortion", {"drive_db": 20}), ("gain", {"gain_db": -12})), extend=False)
        b = fx.apply_chain(x, SR, chain(("gain", {"gain_db": -12}), ("distortion", {"drive_db": 20})), extend=False)
        self.assertGreater(float(np.abs(a - b).max()), 1e-3)
        off = [{"type": "gain", "on": False, "params": {"gain_db": 12}}, {"type": "reverb", "on": False}]
        self.assertTrue(np.array_equal(fx.apply_chain(x, SR, off), x))
        with self.assertRaises(ValueError) as cm:
            fx.apply_chain(x, SR, [{"type": "nope"}])
        self.assertIn("nope", str(cm.exception))
        hi = fx.apply_chain(x, SR, chain(("gain", {"gain_db": 99})), extend=False)
        top = fx.apply_chain(x, SR, chain(("gain", {"gain_db": 24})), extend=False)
        self.assertTrue(np.array_equal(hi, top))
        with self.assertRaises(core.AudioInputError) as cm:
            fx.apply_chain(x, SR, chain(("gain", {"gain_db": "loud"})))
        self.assertEqual(cm.exception.code, "bad_param")

    def test_chain_never_clips(self):
        y = fx.apply_chain(voice(2.0), SR, chain(("gain", {"gain_db": 24}), ("distortion", {"drive_db": 40}),
                                                  ("delay", {"feedback": 0.95, "mix": 1})))
        self.assertTrue(np.isfinite(y).all())
        self.assertLessEqual(float(np.abs(y).max()), 1.0)

    def test_stereo_channels_independent(self):
        x = np.stack([tone(440, 1.0), np.zeros(SR, dtype=np.float32)], axis=1)
        y = fx.apply_chain(x, SR, chain(("gain", {"gain_db": 6}), ("eq", {"mid_db": 6}),
                                         ("compressor", {"threshold_db": -30})), extend=False)
        self.assertEqual(y.shape, x.shape)
        self.assertEqual(float(np.abs(y[:, 1]).max()), 0.0)
        self.assertGreater(float(np.abs(y[:, 0]).max()), 0.1)

    def test_fx_catalog_shape(self):
        effects = fx.fx_catalog({})["effects"]
        ids = [e["id"] for e in effects]
        self.assertEqual(ids[:9], fx.CANONICAL)
        for e in effects:
            self.assertTrue(e["title"])
            for key, spec in e["params"].items():
                self.assertTrue(spec.get("title"), key)
                if "choices" not in spec:
                    self.assertLessEqual(spec["min"], spec["default"])
                    self.assertLessEqual(spec["default"], spec["max"])

    def test_post_synth_hook(self):
        x = tone(440, 1.0)
        with tempfile.TemporaryDirectory() as tmp:
            dry = os.path.join(tmp, "dry.wav")
            y = core.run_post_synth(x, SR, {"chain": [{"type": "gain", "params": {"gain_db": 6.0206}}], "dry_out": dry})
            self.assertEqual(y.ndim, 1)
            self.assertAlmostEqual(float(np.abs(y).max() / np.abs(x).max()), 2.0, delta=0.01)
            d, rate = core.read_audio(dry)
            self.assertEqual(rate, SR)
            self.assertLess(float(np.abs(d - x).max()), 1e-4)
            with self.assertRaises(core.AudioInputError):
                core.run_post_synth(x, SR, {"chain": [{"type": "nope"}]})
        self.assertIs(core.run_post_synth(x, SR, {}), x)
        self.assertIs(core.run_post_synth(x, SR, {"chain": []}), x)

    def test_fx_apply_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, out, dry = (os.path.join(tmp, n) for n in ("in.wav", "out.wav", "dry.wav"))
            write_wav(src, np.stack([tone(440, 1.0), tone(220, 1.0)], axis=1), 44100)
            r = fx.fx_apply({"audio": src, "out": out, "dry_out": dry, "chain": [{"type": "delay"}]})
            y, rate = core.read_audio(out, mono=False)
            self.assertEqual((rate, y.ndim, y.shape[1]), (44100, 2, 2))
            self.assertAlmostEqual(r["tail"], fx._delay_tail(44100, time_ms=300, feedback=0.35, mix=0.3), places=2)
            self.assertAlmostEqual(r["seconds"], len(y) / 44100.0, delta=0.001)
            self.assertEqual(r["path"], out)
            self.assertAlmostEqual(len(y) / 44100.0, SR / 44100.0 + r["tail"], delta=0.01)
            self.assertEqual(core.read_audio(dry, mono=False)[0].shape[0], SR)

    def test_chain_speed(self):
        x = voice(60.0)
        c = [{"type": n} for n in fx.CANONICAL]
        start = time.time()
        y = fx.apply_chain(x, SR, c)
        elapsed = time.time() - start
        self.assertTrue(np.isfinite(y).all())
        self.assertLess(elapsed, 20.0, elapsed)


if __name__ == "__main__":
    unittest.main()
