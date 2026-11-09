"""Tests for Sources/cns_dfn.py: pinned download, command building with a fake binary, the Enhance hook."""
import hashlib
import http.server
import json
import os
import pathlib
import shlex
import sys
import tempfile
import threading
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
    import cns_dfn as dfn
    from audio_fixtures import speechlike, tone, write_wav

STUB_BODY = b"#!/bin/sh\necho deep_filter 0.5.6\n"

# Records argv and the input's header, copies the input to -o <dir>. `help` decides what --help lists.
FAKE = """#!/bin/sh
exec %(py)s - "$@" <<'PYEOF'
import json, os, shutil, sys, wave
a = sys.argv[1:]
if "--help" in a:
    print(%(help)r); sys.exit(0)
if "--version" in a:
    print("deep_filter 0.5.6"); sys.exit(0)
if os.path.exists(%(fail)r):
    print("boom", file=sys.stderr); sys.exit(3)
w = wave.open(a[-1])
with open(%(log)r, "a") as f:
    f.write(json.dumps({"argv": a, "rate": w.getframerate(), "ch": w.getnchannels(), "width": w.getsampwidth()}) + "\\n")
w.close()
out = a[a.index("-o") + 1]
os.makedirs(out, exist_ok=True)
shutil.copy(a[-1], os.path.join(out, os.path.basename(a[-1])))
PYEOF
"""


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class DfnTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name
        keep = (dfn.BINARY, dfn.URL, dfn.SHA256, dfn.SIZE)

        def restore():
            dfn.BINARY, dfn.URL, dfn.SHA256, dfn.SIZE = keep
        self.addCleanup(restore)
        dfn.BINARY = os.path.join(self.dir, "bin", "deep-filter")
        self.log = os.path.join(self.dir, "log.jsonl")
        self.fail = os.path.join(self.dir, "fail.flag")
        self.made = []
        real = tempfile.mkdtemp

        def spy(*a, **k):
            d = real(*a, **k)
            if k.get("prefix", "").startswith("cns-dfn"):
                self.made.append(d)
            return d
        tempfile.mkdtemp = spy
        self.addCleanup(lambda: setattr(tempfile, "mkdtemp", real))

    def fake(self, help_text="  -a, --atten-lim-db <X>"):
        os.makedirs(os.path.dirname(dfn.BINARY), exist_ok=True)
        with open(dfn.BINARY, "w") as f:
            f.write(FAKE % {"py": shlex.quote(sys.executable), "help": help_text, "log": self.log, "fail": self.fail})
        os.chmod(dfn.BINARY, 0o755)

    def calls(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f if line.strip()]

    def serve(self, body):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return "http://127.0.0.1:%d/deep-filter" % srv.server_address[1]

    def pin_stub(self):
        dfn.URL = self.serve(STUB_BODY)
        dfn.SIZE = len(STUB_BODY)
        dfn.SHA256 = hashlib.sha256(STUB_BODY).hexdigest()

    def test_constants_shape(self):
        self.assertEqual(len(dfn.SHA256), 64)
        int(dfn.SHA256, 16)
        self.assertIn("v0.5.6", dfn.URL)
        self.assertIn("aarch64-apple-darwin", dfn.URL)
        self.assertEqual(dfn.VERSION, "0.5.6")
        self.assertEqual(dfn.SIZE, 27877081)

    def test_install_verifies_sha_and_size(self):
        self.pin_stub()
        self.assertEqual(dfn.dfn_install({}), {"installed": True})
        st = dfn.dfn_status({})
        self.assertTrue(st["installed"])
        self.assertEqual(st["version"], "0.5.6")
        self.assertEqual(st["size"], len(STUB_BODY))
        self.assertTrue(os.access(dfn.BINARY, os.X_OK))
        self.assertFalse(os.path.exists(dfn.BINARY + ".part"))
        dfn.dfn_remove({})
        self.assertFalse(dfn.dfn_status({})["installed"])
        dfn.SHA256 = "0" * 64
        with self.assertRaises(Exception) as cm:
            dfn.dfn_install({})
        self.assertIn("checksum", str(cm.exception))
        self.assertFalse(os.path.exists(dfn.BINARY))
        self.assertFalse(os.path.exists(dfn.BINARY + ".part"))
        self.assertFalse(dfn.dfn_status({})["installed"])
        dfn.SHA256 = hashlib.sha256(STUB_BODY).hexdigest()
        dfn.SIZE = len(STUB_BODY) + 5
        with self.assertRaises(Exception):
            dfn.dfn_install({})
        self.assertFalse(dfn.dfn_status({})["installed"])

    def test_partial_download_is_not_installed(self):
        os.makedirs(os.path.dirname(dfn.BINARY))
        with open(dfn.BINARY + ".part", "wb") as f:
            f.write(b"half")
        self.assertFalse(dfn.dfn_status({})["installed"])
        self.pin_stub()
        dfn.dfn_install({})
        self.assertTrue(dfn.dfn_status({})["installed"])
        self.assertFalse(os.path.exists(dfn.BINARY + ".part"))

    def test_apply_builds_command(self):
        self.fake()
        src, dst = os.path.join(self.dir, "in.wav"), os.path.join(self.dir, "out.wav")
        write_wav(src, np.stack([tone(300, 0.5, 8000), tone(500, 0.5, 8000)], axis=1), 8000)
        r = dfn.dfn_apply({"audio": src, "out": dst, "strength_db": 12})
        self.assertEqual(r["path"], dst)
        self.assertIsNone(r["snr_hint"])
        calls = self.calls()
        self.assertEqual(len(calls), 2)  # one run per channel
        for c in calls:
            a = c["argv"]
            self.assertIn("-D", a)
            self.assertEqual(a[a.index("-a") + 1], "12")
            self.assertIn("-o", a)
            self.assertEqual((c["rate"], c["ch"], c["width"]), (48000, 1, 2))
        y, rate = core.read_audio(dst, mono=False)
        self.assertEqual(rate, 8000)
        self.assertEqual(y.shape[1], 2)
        self.assertLessEqual(abs(len(y) - 4000), 1)

    def test_strength_is_clamped(self):
        self.fake()
        x = tone(300, 0.3, 48000)
        dfn.dfn_denoise(x, 48000, 0)
        dfn.dfn_denoise(x, 48000, 99)
        got = [c["argv"][c["argv"].index("-a") + 1] for c in self.calls()]
        self.assertEqual(got, ["1", "30"])
        with self.assertRaises(core.AudioInputError):
            dfn.dfn_denoise(x, 48000, "loud")

    def test_strength_mixes_without_flag(self):
        self.fake(help_text="no limit option")
        x = tone(300, 0.3, 48000)
        y = dfn.dfn_denoise(x, 48000, 15)  # the fake returns the input (quantised), so any mix equals it
        self.assertNotIn("-a", self.calls()[0]["argv"])
        self.assertLess(float(np.abs(y - x).max()), 1e-3)

    def test_missing_binary_error_has_action(self):
        for call in (lambda: dfn.dfn_denoise(tone(300, 0.3, 48000), 48000, 18),
                     lambda: dfn.dfn_apply({"audio": "x.wav", "out": "y.wav"})):
            with self.assertRaises(core.AudioInputError) as cm:
                call()
            self.assertEqual(cm.exception.code, "unsupported")
            self.assertIn("Download DeepFilterNet in Audio Tools", cm.exception.message)

    def test_tmp_dirs_removed(self):
        self.fake()
        dfn.dfn_denoise(tone(300, 0.3, 24000), 24000, 18)
        self.assertTrue(self.made)
        self.assertFalse(any(os.path.exists(d) for d in self.made))
        open(self.fail, "w").close()
        n = len(self.made)
        with self.assertRaises(RuntimeError) as cm:
            dfn.dfn_denoise(tone(300, 0.3, 24000), 24000, 18)
        self.assertIn("boom", str(cm.exception))
        self.assertGreater(len(self.made), n)
        self.assertFalse(any(os.path.exists(d) for d in self.made))

    def test_pre_enhance_hook(self):
        self.fake()
        src = os.path.join(self.dir, "s.wav")
        write_wav(src, speechlike(1.0, 16000), 16000)
        req = {"audio": src, "mode": "dfn", "strength_db": 10}
        wav = np.zeros(24000, dtype=np.float32)
        out = core.run_pre_enhance(req, wav, 24000)
        self.assertIs(req["denoise"], False)
        self.assertEqual(len(self.calls()), 1)
        self.assertLessEqual(abs(len(out) - 24000), 1)
        self.assertGreater(float(np.abs(out).max()), 0.01)
        req2 = {"audio": src, "mode": "gate"}
        out2 = core.run_pre_enhance(req2, wav, 24000)
        self.assertIs(out2, wav)
        self.assertNotIn("denoise", req2)
        self.assertEqual(len(self.calls()), 1)

    def test_pre_enhance_missing_binary_raises_input_error(self):
        src = os.path.join(self.dir, "s.wav")
        write_wav(src, speechlike(1.0, 16000), 16000)
        with self.assertRaises(core.AudioInputError) as cm:
            core.run_pre_enhance({"audio": src, "mode": "dfn"}, np.zeros(10, dtype=np.float32), 24000)
        self.assertIn("Download DeepFilterNet in Audio Tools", cm.exception.message)

    def test_pre_enhance_failure_propagates(self):
        self.fake()
        open(self.fail, "w").close()
        src = os.path.join(self.dir, "s.wav")
        write_wav(src, speechlike(1.0, 16000), 16000)
        req = {"audio": src, "mode": "dfn"}
        with self.assertRaises(core.AudioInputError) as cm:
            core.run_pre_enhance(req, np.zeros(10, dtype=np.float32), 24000)
        self.assertEqual(cm.exception.code, "unsupported")
        self.assertIn("boom", cm.exception.message)
        self.assertIn("Audio Tools", cm.exception.message)
        self.assertNotIn("denoise", req)

    def test_oversize_download_is_stopped(self):
        self.pin_stub()
        dfn.SIZE = len(STUB_BODY) - 5
        with self.assertRaises(RuntimeError) as cm:
            dfn.dfn_install({})
        self.assertIn("larger than expected", str(cm.exception))
        self.assertFalse(os.path.exists(dfn.BINARY + ".part"))
        self.assertFalse(dfn.dfn_status({})["installed"])

    def test_network_error_has_action(self):
        dfn.URL = "http://127.0.0.1:1/deep-filter"
        with self.assertRaises(RuntimeError) as cm:
            dfn.dfn_install({})
        self.assertIn("Check the connection and try again", str(cm.exception))
        self.assertFalse(os.path.exists(dfn.BINARY + ".part"))

    def test_url_is_https(self):
        self.assertTrue(dfn.URL.startswith("https://"))

    def test_binary_dir_read_at_call_time(self):
        dfn.BINARY = dfn._IMPORT_BINARY
        old = os.environ.get("CNS_BIN_DIR")
        self.addCleanup(lambda: os.environ.pop("CNS_BIN_DIR", None) if old is None
                        else os.environ.__setitem__("CNS_BIN_DIR", old))
        os.environ["CNS_BIN_DIR"] = os.path.join(self.dir, "elsewhere")
        self.assertEqual(dfn._bin(), os.path.join(self.dir, "elsewhere", "deep-filter"))

    def test_registered(self):
        for name in ("dfn_status", "dfn_install", "dfn_remove", "dfn_apply"):
            self.assertIn(name, dfn.COMMANDS)
        self.assertIn("dfn_apply", core.TOOLS)
        self.assertTrue(callable(core.TOOLS["dfn_apply"]["setup"]))


REAL = os.environ.get("CNS_DFN_BINARY", "")


@unittest.skipIf(np is None or not (REAL and os.path.isfile(REAL)),
                 "set CNS_DFN_BINARY to a real deep-filter binary to run this")
class DfnRealBinary(unittest.TestCase):
    def test_real_binary_improves_snr(self):
        old = dfn.BINARY
        dfn.BINARY = REAL
        try:
            sr = 24000
            clean = speechlike(6, sr)
            rng = np.random.default_rng(3)
            t = np.arange(len(clean)) / sr
            # Loud enough that the network sees noise: its buzzy synthetic "voice" is only half speech to it,
            # so a quiet noise floor is not improved (measured: SI-SDR 1.4 -> 7.9 dB at 18 dB strength).
            noise = 0.05 * rng.standard_normal(len(clean)) + 0.05 * np.sin(2 * np.pi * 50 * t)
            noisy = (clean + noise).astype(np.float32)
            out = dfn.dfn_denoise(noisy, sr, 18)

            def si_sdr(est, ref):
                n = min(len(est), len(ref))
                est, ref = est[:n].astype(np.float64), ref[:n].astype(np.float64)
                a = (est @ ref) / (ref @ ref)
                return 10 * np.log10(((a * ref) ** 2).sum() / (((a * ref) - est) ** 2).sum())
            before, after = si_sdr(noisy, clean), si_sdr(out, clean)
            print("SI-SDR %.1f -> %.1f dB" % (before, after), file=sys.stderr)
            self.assertGreaterEqual(after - before, 3.0)
        finally:
            dfn.BINARY = old


if __name__ == "__main__":
    unittest.main()
