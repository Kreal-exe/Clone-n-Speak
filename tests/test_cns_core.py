"""Tests for Sources/cns_core.py: audio input/output, moved DSP, registries and module auto-loading."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

try:
    import numpy as np
    import scipy  # noqa: F401
except ImportError:
    np = None

SOURCES = pathlib.Path(__file__).resolve().parent.parent / "Sources"
sys.path.insert(0, str(SOURCES))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

if np is not None:
    import cns_core as core
    from audio_fixtures import SR, tone, voice, write_wav


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class CoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def p(self, name):
        return os.path.join(self.dir, name)

    def test_read_audio_mono_stereo_rates(self):
        for rate in (8000, 16000, 22050, 24000, 44100, 48000, 96000):
            for ch in (1, 2):
                with self.subTest(rate=rate, ch=ch):
                    base = tone(440, 0.6, rate)
                    wav = base if ch == 1 else np.stack([base, base * 0.5], axis=1)
                    path = self.p("a.wav")
                    write_wav(path, wav, rate)
                    x, r = core.read_audio(path)
                    self.assertEqual((x.shape, r, x.dtype), ((len(base),), rate, np.float32))
                    y, r = core.read_audio(path, sr=24000)
                    self.assertEqual(r, 24000)
                    self.assertLessEqual(abs(len(y) - round(len(base) * 24000 / rate)), 1)
                    if ch == 2:
                        s, _ = core.read_audio(path, mono=False)
                        self.assertEqual(s.shape, (len(base), 2))

    def test_read_audio_int_formats(self):
        base = tone(300, 0.5, 24000, amp=0.6)
        peaks = []
        for sub in ("pcm16", "pcm24", "float32", "pcm32"):
            path = self.p(sub + ".wav")
            write_wav(path, base, 24000, sub)
            x, _ = core.read_audio(path)
            peaks.append(float(np.abs(x).max()))
        for pk in peaks:
            self.assertAlmostEqual(pk, peaks[0], delta=1e-3)
        self.assertAlmostEqual(peaks[0], 0.6, delta=1e-3)

    def test_errors_have_codes(self):
        def code_of(path, **kw):
            with self.assertRaises(core.AudioInputError) as cm:
                core.read_audio(path, **kw)
            e = cm.exception
            self.assertTrue(e.message and str(e) == e.message)
            self.assertNotIn("Traceback", e.message)
            self.assertRegex(e.message, r"\b(Choose|Cut|Convert|Use|Record|Pick)\b")
            return e.code
        empty = self.p("empty.wav")
        open(empty, "wb").close()
        self.assertEqual(code_of(empty), "empty")
        short = self.p("short.wav")
        write_wav(short, tone(440, 0.2, 24000), 24000)
        self.assertEqual(code_of(short, min_seconds=0.5), "too_short")
        zeros = self.p("zeros.wav")
        write_wav(zeros, np.zeros(24000, dtype=np.float32), 24000)
        self.assertEqual(code_of(zeros, allow_silent=False), "silent")
        core.read_audio(zeros)  # silence is fine unless refused
        text = self.p("notes.txt")
        with open(text, "w") as f:
            f.write("this is not audio\n" * 20)
        self.assertEqual(code_of(text), "unsupported")
        fake = self.p("fake.wav")
        with open(fake, "w") as f:
            f.write("this is not audio\n" * 20)
        self.assertEqual(code_of(fake), "unsupported")
        long_ = self.p("long.wav")
        write_wav(long_, np.zeros(1800 * 8000, dtype=np.float32), 8000)
        self.assertEqual(code_of(long_), "too_long")
        self.assertEqual(code_of(self.p("missing.wav")), "empty")

    def test_write_audio_atomic(self):
        path = self.p("out.wav")
        sec = core.write_audio(path, tone(440, 1.0, 24000), 24000)
        self.assertAlmostEqual(sec, 1.0, places=3)
        self.assertEqual(os.listdir(self.dir), ["out.wav"])
        x, _ = core.read_audio(path, mono=False)
        self.assertEqual(x.shape, (24000,))
        for sub in ("pcm24", "float32"):
            stereo = np.stack([tone(440, 0.5, 24000), tone(660, 0.5, 24000)], axis=1)
            core.write_audio(self.p(sub + ".wav"), stereo, 24000, subtype=sub)
            y, _ = core.read_audio(self.p(sub + ".wav"), mono=False)
            self.assertEqual(y.shape, (12000, 2))
            self.assertAlmostEqual(float(np.abs(y).max()), 0.3, delta=1e-3)
        # a failure in the middle leaves neither the target nor the .part file
        target = self.p("never.wav")
        with self.assertRaises(ValueError):
            core.write_audio(target, tone(440, 0.1, 24000), 24000, subtype="mp3")
        with self.assertRaises(Exception):
            core.write_audio(target, np.zeros((10, 2, 2)), 24000)
        self.assertFalse(os.path.exists(target))
        self.assertFalse(os.path.exists(target + ".part"))
        # an existing file survives a failed rewrite
        before = open(path, "rb").read()
        with self.assertRaises(ValueError):
            core.write_audio(path, tone(440, 0.1, 24000), 24000, subtype="bogus")
        self.assertEqual(open(path, "rb").read(), before)
        self.assertFalse(os.path.exists(path + ".part"))

    def test_resample_and_map_channels(self):
        stereo = np.stack([tone(440, 0.5, 48000), tone(440, 0.5, 48000)], axis=1)
        self.assertEqual(core.resample(stereo, 48000, 24000).shape, (12000, 2))
        out = core.map_channels(stereo, lambda c: c * 0.5)
        self.assertEqual(out.shape, stereo.shape)
        self.assertAlmostEqual(float(np.abs(out).max()), float(np.abs(stereo).max()) * 0.5, places=5)
        self.assertEqual(core.map_channels(stereo[:, 0], lambda c: c).shape, (24000,))

    def test_biquad_compress_moved(self):
        # a 0 dB peak is the identity filter
        sos = core.biquad("peak", 3000, 0.0, SR, q=0.9)
        np.testing.assert_allclose(sos[:3], sos[3:], atol=1e-9)
        self.assertAlmostEqual(float(sos[3]), 1.0)
        # the tone test of test_worker_audio, on the moved functions
        from scipy.signal import sosfilt
        rng = np.random.default_rng(1)
        noise = (0.05 * rng.standard_normal(SR * 2)).astype(np.float32)

        def bands(x):
            spec = np.abs(np.fft.rfft(x)) ** 2
            freq = np.fft.rfftfreq(len(x), 1 / SR)
            return spec[freq < 150].sum(), spec[freq > 6000].sum()
        low0, high0 = bands(noise)
        bright = sosfilt(np.array([core.biquad("low", 220, -3.0, SR), core.biquad("high", 3800, 4.0, SR)]), noise)
        low, high = bands(bright)
        self.assertGreater(high / low, high0 / low0)
        loud = tone(440, 1.0, SR, amp=0.9)
        squeezed = core.compress(loud, 1.0)
        self.assertLess(float(np.abs(squeezed).max()), 0.9 * 0.8)
        quiet = tone(440, 1.0, SR, amp=0.01)
        np.testing.assert_allclose(core.compress(quiet, 1.0), quiet, atol=1e-6)
        import importlib.util
        spec = importlib.util.spec_from_file_location("worker_for_core", SOURCES / "worker.py")
        worker = importlib.util.module_from_spec(spec)
        keep = sys.stdout
        spec.loader.exec_module(worker)
        sys.stdout = keep
        self.assertIs(worker._biquad, core.biquad)
        self.assertIs(worker._compress, core.compress)
        self.assertIs(worker.track_f0, core.track_f0)
        self.assertIs(worker.frames_db, core.frames_db)

    def test_quality_report_keys(self):
        wav = voice(5)
        r = core.quality_report(wav, SR)
        self.assertEqual(set(r), {"seconds", "rms_db", "peak", "clipping", "snr_db", "voiced", "issues", "score"})
        # the body of the former cmd_analyze, kept here as the reference
        db = core.frames_db(wav)
        noise, speech = float(np.percentile(db, 10)), float(np.percentile(db, 90))
        rms_db = float(20 * np.log10(np.sqrt((wav ** 2).mean() + 1e-12)))
        issues = []
        if len(wav) / SR < 3:
            issues.append("short")
        if len(wav) / SR > 15:
            issues.append("long")
        if float((np.abs(wav) > 0.985).mean()) > 0.001:
            issues.append("clipping")
        if speech - noise < 25:
            issues.append("noisy")
        if rms_db < -32:
            issues.append("quiet")
        if float((db > noise + 12).mean()) < 0.45:
            issues.append("pauses")
        want = {"seconds": 5.0, "rms_db": round(rms_db, 1), "peak": round(float(np.abs(wav).max()), 3),
                "clipping": round(float((np.abs(wav) > 0.985).mean()), 4), "snr_db": round(speech - noise, 1),
                "voiced": round(float((db > noise + 12).mean()), 2), "issues": issues,
                "score": int(max(5, min(100, 100 - 18 * len(issues) - max(0, 30 - (speech - noise)))))}
        self.assertEqual(r, want)

    def test_register_effect_validates(self):
        def fn(wav, sr, amount=0.5):
            return wav
        good = {"amount": {"min": 0.0, "max": 1.0, "default": 0.5, "unit": "", "title": "Amount"}}
        name = "test_fx_%d" % os.getpid()
        try:
            core.register_effect(name, fn, good, tail=lambda sr, amount=0.5: 0.0, title="Test")
            self.assertEqual(core.EFFECTS[name]["title"], "Test")
            self.assertIs(core.EFFECTS[name]["fn"], fn)
            with self.assertRaises(ValueError):
                core.register_effect(name, fn, good)
            for bad in ({"min": 1.0, "max": 0.0, "default": 0.5}, {"min": 0.0, "max": 1.0, "default": 2.0},
                        {"min": 0.0, "max": 1.0, "default": -1.0}, {"min": 0.0, "max": 1.0}):
                with self.assertRaises(ValueError):
                    core.register_effect(name + "_bad", fn, {"amount": bad})
            self.assertNotIn(name + "_bad", core.EFFECTS)
            with self.assertRaises(ValueError):
                core.register_effect(name + "_c", fn, {"mode": {"choices": ["a", "b"], "default": "c"}})
            core.register_effect(name + "_c", fn, {"mode": {"choices": ["a", "b"], "default": "a"}})
        finally:
            for k in [k for k in core.EFFECTS if k.startswith(name)]:
                del core.EFFECTS[k]

    def test_hooks_run_in_order_and_survive_failures(self):
        def boom(wav, sr, req):
            raise RuntimeError("boom")
        post = [lambda w, sr, req: w + 1, boom, lambda w, sr, req: w * 2]
        pre = [lambda req, w, sr: w - req["k"]]
        core.POST_SYNTH.extend(post)
        core.PRE_ENHANCE.extend(pre)
        try:
            np.testing.assert_allclose(core.run_post_synth(np.zeros(3), SR, {}), [2, 2, 2])
            np.testing.assert_allclose(core.run_pre_enhance({"k": 2}, np.zeros(3), SR), [-2, -2, -2])
        finally:
            for h in post:
                core.POST_SYNTH.remove(h)
            for h in pre:
                core.PRE_ENHANCE.remove(h)

    def test_autoload_survives_broken_module(self):
        with open(self.p("cns_ok.py"), "w") as f:
            f.write("def f(req):\n    return {}\nCOMMANDS = {'ok': f}\n")
        with open(self.p("cns_bad.py"), "w") as f:
            f.write("raise RuntimeError('broken on purpose')\n")
        with open(self.p("cns_syntax.py"), "w") as f:
            f.write("def (:\n")
        commands = {"keep": 1}
        try:
            loaded = core.load_modules(commands, self.dir)
            self.assertEqual(loaded, ["cns_ok"])
            self.assertIn("ok", commands)
            self.assertEqual(commands["keep"], 1)
            self.assertEqual(core.load_modules({}, self.dir), ["cns_ok"])  # loading twice is harmless
        finally:
            for n in ("cns_ok", "cns_bad", "cns_syntax"):
                sys.modules.pop(n, None)

    def test_events_are_bound(self):
        seen = []
        core.bind(emit=lambda ev, **d: seen.append((ev, d)), status=lambda m: seen.append(("status", m)),
                  free=lambda: seen.append("free"))
        try:
            core.emit_progress(0.5)
            core.emit_status("hi")
            core.free_models()
        finally:
            core.bind()
        self.assertEqual(seen, [("progress", {"value": 0.5}), ("status", "hi"), "free"])

    def test_no_heavy_imports(self):
        mods = sorted(p.stem for p in SOURCES.glob("cns_*.py"))
        code = ("import sys; sys.path.insert(0, %r); import %s; "
                "bad = [m for m in ('torch','mlx','matplotlib','librosa','soundfile','onnxruntime') if m in sys.modules]; "
                "print(','.join(bad))") % (str(SOURCES), ", ".join(mods))
        out = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
