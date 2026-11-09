"""Every registered audio tool (core.TOOLS) must take awkward input: any rate, channel count, sample format,
length and silence. Each module adds its own entry to core.TOOLS, so the matrix grows by itself.

A TOOLS entry: {"request": callable(in_path, out_path) -> request dict (with "cmd"), "setup": callable(tmpdir) ->
ctx | None (a callable ctx is called afterwards as cleanup), "streams": False, "no_output": True (optional, for
analysis-only tools: no output WAV is expected, the result must be JSON-serialisable without NaN / inf), "verify":
callable(result) (optional, extra checks of that result)}."""
import importlib.util
import json
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
    from audio_fixtures import speechlike, write_wav

RATES = (8000, 16000, 22050, 24000, 44100, 48000, 96000)
ALLOWED = {"too_short", "silent", "too_long", "engine_missing"}


def _load_worker():
    spec = importlib.util.spec_from_file_location("worker_tools_inputs", HERE.parent / "Sources" / "worker.py")
    worker = importlib.util.module_from_spec(spec)
    keep = sys.stdout
    spec.loader.exec_module(worker)  # the worker redirects stdout to stderr on import
    sys.stdout = keep
    core.bind(emit=lambda *a, **k: None, status=lambda m: None, free=lambda: None)  # keep the protocol quiet
    return worker


def _cases():
    """(label, rate, channels, subtype, seconds, kind): the full matrix for pcm16, one point per other subtype."""
    out = []
    for rate in RATES:
        for ch in (1, 2):
            for seconds in (0.5, 5.0):
                out.append(("pcm16", rate, ch, "pcm16", seconds, "speech"))
    for sub in ("pcm24", "float32"):
        out.append((sub, 44100, 2, sub, 5.0, "speech"))
    out.append(("silence", 24000, 1, "pcm16", 3.0, "silence"))
    if os.environ.get("CNS_SLOW") == "1":
        out.append(("30min", 8000, 1, "pcm16", 1800.0, "long"))
    return out


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class ToolInputs(unittest.TestCase):
    def test_tools_accept_formats_and_lengths(self):
        worker = _load_worker()
        for name, tool in sorted(core.TOOLS.items()):
            for label, rate, ch, sub, seconds, kind in _cases():
                with self.subTest(tool=name, case=label, rate=rate, ch=ch, seconds=seconds):
                    with tempfile.TemporaryDirectory() as tmp:
                        n = int(rate * seconds)
                        wav = speechlike(seconds, rate) if kind == "speech" else np.zeros(n, dtype=np.float32)
                        if ch == 2:
                            wav = np.stack([wav, wav * 0.7], axis=1)
                        src, dst = os.path.join(tmp, "in.wav"), os.path.join(tmp, "out.wav")
                        write_wav(src, wav, rate, sub)
                        ctx = tool["setup"](tmp) if tool.get("setup") else None
                        try:
                            req = tool["request"](src, dst)
                            try:
                                result = worker.COMMANDS[req["cmd"]](req)
                            except core.AudioInputError as e:
                                self.assertIn(e.code, ALLOWED)
                                self.assertTrue(e.message)
                                if kind == "long":
                                    self.assertEqual(e.code, "too_long")
                                continue
                        finally:
                            if callable(ctx):
                                ctx()
                        if kind == "long":
                            self.fail("30 minutes must be refused with too_long")
                        if tool.get("no_output"):
                            json.dumps(result, allow_nan=False)
                            if tool.get("verify"):
                                tool["verify"](result)
                            continue
                        self.assertTrue(os.path.exists(dst))
                        y, _ = core.read_audio(dst, mono=False)
                        self.assertGreater(len(y), 0)
                        self.assertTrue(np.isfinite(y).all())
                        self.assertLessEqual(float(np.abs(y).max()), 1.0)


if __name__ == "__main__":
    unittest.main()
