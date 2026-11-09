"""Tests for Sources/cns_separate.py (music removal). No network and no onnxruntime: the session is a stand-in.

Integration (needs the real model): CNS_TEST_MODEL=/path/Kim_Vocal_2.onnx and onnxruntime installed."""
import hashlib
import io
import os
import pathlib
import re
import sys
import tempfile
import tracemalloc
import unittest
from unittest import mock

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
    import cns_separate as sep
    from audio_fixtures import write_wav
    PARAMS = dict(sep.CATALOG[0]["params"], compensate=1.0)


class Stub:
    """Behaves like an onnxruntime session: returns `gain` times the spectrogram it is given."""

    class _In:
        name = "input"

    def __init__(self, gain=1.0):
        self.gain = gain
        self.calls = 0

    def get_inputs(self):
        return [self._In()]

    def run(self, outputs, feed):
        self.calls += 1
        return [feed["input"] * self.gain]


def lowpassed_noise(seconds, sr=44100, cutoff=8000, seed=3, channels=2, amp=0.4):
    """Band-limited noise: the network only sees bins below ~17.6 kHz, so a test signal has to stay under it."""
    rng = np.random.default_rng(seed)
    n = int(seconds * sr)
    out = []
    for _ in range(channels):
        spec = np.fft.rfft(rng.standard_normal(n))
        spec[int(cutoff * n / sr):] = 0
        x = np.fft.irfft(spec, n)
        x = x / np.abs(x).max() * amp
        f = int(0.05 * sr)  # fades: an abrupt start has content above the network's band, which it drops
        x[:f] *= np.linspace(0, 1, f)
        x[-f:] *= np.linspace(1, 0, f)
        out.append(x)
    return np.stack(out).astype(np.float32)


def snr_db(ref, est):
    ref, est = np.asarray(ref, np.float64), np.asarray(est, np.float64)
    return 10 * np.log10((ref ** 2).sum() / (((ref - est) ** 2).sum() + 1e-20))


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class SeparateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def path(self, name):
        return os.path.join(self.dir, name)

    def fake_engine(self, gain=0.5):
        """Patches the engine checks and the session, so sep_vocals / the hook run without onnxruntime."""
        stub = Stub(gain)
        p1 = mock.patch.object(sep, "_prepare", lambda entry, directory: "stub")
        p2 = mock.patch.object(sep, "_open_session", lambda path: stub)
        for p in (p1, p2):
            p.start()
            self.addCleanup(p.stop)
        return stub

    # ---- signal path ----------------------------------------------------
    def test_stft_roundtrip(self):
        x = np.random.default_rng(1).standard_normal(3 * 44100).astype(np.float32)
        spec = sep.stft(x, 7680, 1024)
        self.assertEqual(spec.shape[0], 3841)
        y = sep.istft(spec, 7680, 1024, len(x))
        self.assertGreaterEqual(snr_db(x, y), 60)

    def test_chunking_identity(self):
        mix = lowpassed_noise(25)
        stub = Stub()
        out = sep.separate(mix, stub, PARAMS)
        self.assertGreaterEqual(stub.calls, 4)
        self.assertEqual(out.shape, mix.shape)
        self.assertGreaterEqual(snr_db(mix, out), 40)
        gen = 1024 * 255 - 7680  # also across the seams between chunks
        for seam in range(gen, mix.shape[1], gen):
            self.assertGreaterEqual(snr_db(mix[:, seam - 2000:seam + 2000], out[:, seam - 2000:seam + 2000]), 40)

    def test_progress_reaches_one(self):
        seen = []
        sep.separate(lowpassed_noise(8), Stub(), PARAMS, seen.append)
        self.assertEqual(seen[-1], 1.0)
        self.assertEqual(seen, sorted(seen))

    def test_stub_half_vocals(self):
        self.fake_engine(0.5)
        mix = lowpassed_noise(6, amp=0.5)
        src = self.path("mix.wav")
        write_wav(src, mix.T, 44100)
        stems = {}
        for stem in ("vocals", "music"):
            r = sep.sep_vocals({"audio": src, "out": self.path(stem + ".wav"), "stem": stem})
            self.assertEqual(r["stem"], stem)
            stems[stem], _ = core.read_audio(r["path"], mono=False)
        ref, _ = core.read_audio(src, mono=False)
        # compensate 1.009 of the catalog lifts the voice to 0.5045 of the mix, the music is the rest
        k = sep.CATALOG[0]["params"]["compensate"] * 0.5
        self.assertLess(np.abs(stems["vocals"] - k * ref).max(), 0.002)
        self.assertLess(np.abs(stems["music"] - (1 - k) * ref).max(), 0.002)
        self.assertLess(np.abs(stems["vocals"] + stems["music"] - ref).max(), 1e-4)

    def test_rate_and_channels_restored(self):
        self.fake_engine(0.5)
        for rate, ch in ((16000, 1), (48000, 2), (22050, 1)):
            with self.subTest(rate=rate, ch=ch):
                x = lowpassed_noise(3, sr=rate, cutoff=min(6000, rate // 2 - 500), channels=ch)
                src, dst = self.path("in%d.wav" % rate), self.path("out%d.wav" % rate)
                write_wav(src, x[0] if ch == 1 else x.T, rate)
                sep.sep_vocals({"audio": src, "out": dst, "stem": "vocals"})
                y, yr = core.read_audio(dst, mono=False)
                self.assertEqual(yr, rate)
                self.assertEqual(y.ndim, 1 if ch == 1 else 2)
                self.assertEqual(len(y), x.shape[1])
                ref, _ = core.read_audio(src, mono=False)  # content survives the rate round trip
                self.assertGreaterEqual(snr_db(sep.CATALOG[0]["params"]["compensate"] * 0.5 * ref, y), 30)

    def test_loud_stem_is_scaled_not_clipped(self):
        self.fake_engine(3.0)
        src = self.path("loud.wav")
        write_wav(src, lowpassed_noise(3, amp=0.5).T, 44100)
        sep.sep_vocals({"audio": src, "out": self.path("o.wav"), "stem": "vocals"})
        y, _ = core.read_audio(self.path("o.wav"), mono=False)
        self.assertLessEqual(float(np.abs(y).max()), 1.0)
        self.assertGreater(float(np.abs(y).max()), 0.95)

    def test_memory_bound(self):
        mix = lowpassed_noise(60)
        tracemalloc.start()
        try:
            sep.separate(mix, Stub(), PARAMS)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 400 * 1024 * 1024, peak)

    # ---- ordering and hooks ---------------------------------------------
    def test_free_models_called_first(self):
        order = []
        with mock.patch.object(sep, "_prepare", lambda e, d: "stub"), \
                mock.patch.object(sep.core, "free_models", lambda: order.append("free")), \
                mock.patch.object(sep, "_open_session", lambda p: order.append("session") or Stub(0.5)):
            src = self.path("a.wav")
            write_wav(src, lowpassed_noise(2).T, 44100)
            sep.sep_vocals({"audio": src, "out": self.path("b.wav")})
        self.assertEqual(order, ["free", "session"])

    def test_session_is_released(self):
        import weakref
        refs = []

        def open_session(path):
            s = Stub(0.5)
            refs.append(weakref.ref(s))
            return s
        with mock.patch.object(sep, "_prepare", lambda e, d: "stub"), mock.patch.object(sep, "_open_session", open_session):
            src = self.path("a.wav")
            write_wav(src, lowpassed_noise(2).T, 44100)
            sep.sep_vocals({"audio": src, "out": self.path("b.wav")})
        self.assertIsNone(refs[0]())

    def test_pre_enhance_music_mode_returns_voice(self):
        self.fake_engine(0.5)
        wav = lowpassed_noise(3, sr=24000, cutoff=6000, channels=1)[0]
        self.assertIn(sep._pre_enhance, core.PRE_ENHANCE)
        same = sep._pre_enhance({"mode": "voice"}, wav, 24000)
        self.assertIs(same, wav)
        voice = sep._pre_enhance({"mode": "music"}, wav, 24000)
        self.assertEqual(voice.shape, wav.shape)
        self.assertAlmostEqual(float(np.abs(voice).max() / np.abs(wav).max()), 0.5, delta=0.02)

    def test_pre_enhance_without_engine_is_an_error_not_a_skip(self):
        with mock.patch.object(sep, "_onnxruntime_present", lambda: False):
            with self.assertRaises(core.AudioInputError):
                core.run_pre_enhance({"mode": "music", "dir": self.dir}, np.zeros(24000, np.float32), 24000)

    def test_registered_in_tools(self):
        tool = core.TOOLS["sep_vocals"]
        self.assertEqual(tool["request"]("a", "b")["cmd"], "sep_vocals")
        cleanup = tool["setup"](self.dir)
        try:
            self.assertEqual(sep._prepare(None, None), "stub")
        finally:
            cleanup()
        self.assertNotEqual(sep._prepare.__name__, "<lambda>")

    # ---- the model file -------------------------------------------------
    def entry(self, payload):
        e = dict(sep.CATALOG[0])
        e.update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), url="https://example.invalid/m.onnx")
        return e

    def test_install_model_checks_hash_and_size(self):
        payload = os.urandom(300000)
        e = self.entry(payload)
        seen = []
        with mock.patch.object(sep, "CATALOG", [e]), \
                mock.patch.object(sep, "_open_url", lambda url: io.BytesIO(payload)):
            self.assertFalse(sep.sep_status({"dir": self.dir})["model_ready"])
            out = sep.sep_install_model({"id": e["id"], "dir": self.dir})
            self.assertEqual(out, {"model_ready": True})
            self.assertTrue(sep.sep_status({"dir": self.dir})["model_ready"])
            self.assertFalse(os.path.exists(os.path.join(self.dir, e["file"] + ".part")))
            sep._download(e, self.dir + "/x", seen.append)
            self.assertEqual(seen[-1], 1.0)
            sep.sep_remove_model({"id": e["id"], "dir": self.dir})
            self.assertFalse(sep.sep_status({"dir": self.dir})["model_ready"])

    def test_model_checksum(self):
        payload = os.urandom(100000)
        e = self.entry(payload)
        bad = bytearray(payload)
        bad[5] ^= 1
        with mock.patch.object(sep, "CATALOG", [e]), \
                mock.patch.object(sep, "_open_url", lambda url: io.BytesIO(bytes(bad))):
            with self.assertRaises(sep.ModelDownloadError) as cm:
                sep.sep_install_model({"id": e["id"], "dir": self.dir})
        self.assertIn("checksum", str(cm.exception))
        self.assertEqual(os.listdir(self.dir), [])

    def test_part_file_is_not_a_ready_model(self):
        e = dict(sep.CATALOG[0])
        with open(os.path.join(self.dir, e["file"] + ".part"), "wb") as f:
            f.write(b"x" * 1000)
        self.assertFalse(sep._model_ready(e, self.dir))
        with open(os.path.join(self.dir, e["file"]), "wb") as f:  # a truncated final file is not ready either
            f.write(b"x" * 1000)
        self.assertFalse(sep._model_ready(e, self.dir))

    def test_download_failure_is_reported_and_cleaned(self):
        payload = b"abc" * 1000
        e = self.entry(payload)

        def boom(url):
            raise OSError("network down")
        with mock.patch.object(sep, "_open_url", boom):
            with self.assertRaises(sep.ModelDownloadError) as cm:
                sep._download(e, self.dir)
        self.assertIn("internet", str(cm.exception))
        self.assertEqual(os.listdir(self.dir), [])

    def test_download_stops_when_larger_than_entry(self):
        payload = os.urandom(300000)
        e = dict(self.entry(payload), size=1000)
        reads = []

        class Counting(io.BytesIO):
            def read(self, n=-1):
                reads.append(n)
                return super().read(n)
        with mock.patch.object(sep, "_open_url", lambda url: Counting(payload)):
            with self.assertRaises(sep.ModelDownloadError):
                sep._download(e, self.dir)
        self.assertEqual(os.listdir(self.dir), [])
        self.assertEqual(len(reads), 1)

    def test_redirect_to_http_is_refused(self):
        import urllib.error
        import urllib.request
        h = sep._HttpsOnlyRedirect()
        req = urllib.request.Request("https://example.invalid/a")
        with self.assertRaises(urllib.error.URLError):
            h.redirect_request(req, None, 302, "Found", {}, "http://example.invalid/b")
        self.assertIsNotNone(h.redirect_request(req, io.BytesIO(b""), 302, "Found", {}, "https://cdn.invalid/b"))

    def test_model_is_hashed_once_per_process_and_again_after_change(self):
        payload = os.urandom(5000)
        e = self.entry(payload)
        path = os.path.join(self.dir, e["file"])
        with open(path, "wb") as f:
            f.write(payload)
        sep._VERIFIED.clear()
        with mock.patch.object(sep.hashlib, "sha256", wraps=hashlib.sha256) as h:
            sep._verify_model(e, path)
            sep._verify_model(e, path)
            self.assertEqual(h.call_count, 1)
        bad = bytearray(payload)
        bad[0] ^= 1
        with open(path, "wb") as f:
            f.write(bytes(bad))
        os.utime(path, (1, 1))
        with self.assertRaises(sep.EngineMissing) as cm:
            sep._verify_model(e, path)
        self.assertIn("checksum", str(cm.exception))
        self.assertFalse(os.path.exists(path))

    def test_nan_output_is_an_input_error(self):
        self.fake_engine(float("nan"))
        src = self.path("a.wav")
        write_wav(src, lowpassed_noise(2).T, 44100)
        with self.assertRaises(core.AudioInputError) as cm:
            sep.sep_vocals({"audio": src, "out": self.path("b.wav")})
        self.assertIn("Try another recording", str(cm.exception))
        self.assertFalse(os.path.exists(self.path("b.wav")))

    def test_plain_http_is_refused(self):
        e = dict(self.entry(b"abc"), url="http://example.invalid/m.onnx")
        with self.assertRaises(sep.ModelDownloadError):
            sep._download(e, self.dir)

    # ---- missing engine -------------------------------------------------
    def test_missing_engine_error_has_action(self):
        src = self.path("a.wav")
        write_wav(src, lowpassed_noise(2).T, 44100)
        req = {"audio": src, "out": self.path("b.wav"), "dir": self.dir}
        with mock.patch.object(sep, "_onnxruntime_present", lambda: True):  # model missing
            with self.assertRaises(sep.EngineMissing) as cm:
                sep.sep_vocals(req)
        self.assertIn("Download the music-removal engine in Separation (~140 MB)", str(cm.exception))
        e = sep.CATALOG[0]
        with open(os.path.join(self.dir, e["file"]), "wb") as f:
            f.truncate(e["size"])
        with mock.patch.object(sep, "_onnxruntime_present", lambda: False):  # engine missing
            with self.assertRaises(sep.EngineMissing) as cm:
                sep.sep_vocals(req)
        self.assertIn("Download the music-removal engine in Separation (~140 MB)", str(cm.exception))
        self.assertIsInstance(cm.exception, RuntimeError)
        self.assertEqual(cm.exception.code, "engine_missing")
        self.assertFalse(os.path.exists(req["out"]))

    def test_bad_stem_and_unknown_model(self):
        with self.assertRaises(core.AudioInputError) as cm:
            sep.sep_vocals({"audio": "a", "out": "b", "stem": "drums"})
        self.assertEqual(cm.exception.code, "bad_param")
        with self.assertRaises(core.AudioInputError):
            sep.sep_status({"id": "nope"})

    def test_status_reports_without_url(self):
        st = sep.sep_status({"dir": self.dir})
        self.assertNotIn("url", st["model"])
        self.assertEqual(st["model"]["id"], "kim_vocal_2")
        self.assertIsInstance(st["onnxruntime"], bool)
        self.assertEqual(st["size"], 66759214)

    def test_catalog_has_license(self):
        for e in sep.CATALOG:
            self.assertTrue(e["license"].strip())
            self.assertTrue(e["license_url"].startswith("https://"))
            self.assertRegex(e["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(e["url"], r"^https://.*/resolve/[0-9a-f]{40}/")
            self.assertGreater(e["size"], 0)

    def test_commands_autoload_into_worker(self):
        commands = {}
        loaded = core.load_modules(commands)
        self.assertIn("cns_separate", loaded)
        self.assertTrue({"sep_status", "sep_install_model", "sep_remove_model", "sep_vocals"} <= set(commands))

    # ---- integration with the real model --------------------------------
    @unittest.skipUnless(os.environ.get("CNS_TEST_MODEL"), "set CNS_TEST_MODEL to run with the real model")
    def test_real_model_runs(self):
        model = os.environ["CNS_TEST_MODEL"]
        d = self.path("models")
        os.makedirs(d)
        os.symlink(model, os.path.join(d, sep.CATALOG[0]["file"]))
        src = self.path("mix.wav")
        write_wav(src, lowpassed_noise(8, amp=0.3).T, 44100)
        r = sep.sep_vocals({"audio": src, "out": self.path("v.wav"), "dir": d})
        y, _ = core.read_audio(r["path"], mono=False)
        self.assertEqual(len(y), 8 * 44100)
        self.assertTrue(np.isfinite(y).all())


if __name__ == "__main__":
    unittest.main()
