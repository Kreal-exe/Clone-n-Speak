"""worker.py wiring to cns_core: the error event of main() and the post-synth hook in cmd_synth (no models needed)."""
import importlib.util
import io
import json
import pathlib
import sys
import unittest
from unittest import mock

try:
    import numpy as np
    import scipy  # noqa: F401
except ImportError:
    np = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Sources"))


def load_worker():
    spec = importlib.util.spec_from_file_location("worker_wiring", ROOT / "Sources" / "worker.py")
    worker = importlib.util.module_from_spec(spec)
    keep = sys.stdout
    try:
        spec.loader.exec_module(worker)
    finally:
        sys.stdout = keep
    return worker


@unittest.skipIf(np is None, "numpy / scipy are not installed")
class Wiring(unittest.TestCase):
    def run_main(self, worker, requests):
        out = io.StringIO()
        with mock.patch.object(worker, "_proto", out), \
                mock.patch.object(sys, "stdin", io.StringIO("".join(json.dumps(r) + "\n" for r in requests))):
            worker.main()
        return [json.loads(line) for line in out.getvalue().splitlines()]

    def test_main_emits_input_error_with_code_and_plain_message(self):
        worker = load_worker()
        core = sys.modules["cns_core"]

        def too_short(req):
            raise core.AudioInputError("too_short", "Use a recording of at least 3 seconds.")

        def crash(req):
            raise RuntimeError("boom")
        with mock.patch.dict(worker.COMMANDS, {"t_short": too_short, "t_crash": crash}):
            events = self.run_main(worker, [{"cmd": "t_short", "id": 7}, {"cmd": "t_crash", "id": 8}])
        err = [e for e in events if e["event"] == "error"]
        self.assertEqual(err[0], {"event": "error", "msg": "Use a recording of at least 3 seconds.",
                                  "code": "too_short", "id": 7})
        self.assertEqual(err[1]["msg"], "RuntimeError: boom")
        self.assertIn("trace", err[1])
        self.assertNotIn("code", err[1])

    def test_cmd_synth_runs_post_synth_hooks_on_mono(self):
        worker = load_worker()
        core = sys.modules["cns_core"]
        seen = {}

        def hook(wav, sr, req):
            seen["shape"], seen["sr"] = wav.shape, sr
            return wav * 0.5
        take = (0.4 * np.sin(2 * np.pi * 200 * np.arange(12000) / 24000)).astype(np.float32)
        req = {"text": "Hello there.", "language": "en", "model": {"path": "x"}, "out": None}
        import tempfile
        import os
        with tempfile.TemporaryDirectory() as tmp:
            req["out"] = os.path.join(tmp, "o.wav")
            results = {}
            for use_hook in (False, True):
                if use_hook:
                    core.POST_SYNTH.append(hook)
                try:
                    with mock.patch.object(worker, "ensure_tts", return_value=object()), \
                            mock.patch.object(worker, "_speak", return_value=take), \
                            mock.patch.object(worker, "report_memory"), \
                            mock.patch.object(worker, "_progress_window"), \
                            mock.patch.object(worker, "emit"):
                        worker.cmd_synth(dict(req))
                finally:
                    if use_hook:
                        core.POST_SYNTH.remove(hook)
                x, _ = core.read_audio(req["out"])
                results[use_hook] = float(np.abs(x).max())
        self.assertEqual(seen["sr"], 24000)
        self.assertEqual(len(seen["shape"]), 1)
        self.assertAlmostEqual(results[True], results[False] * 0.5, delta=0.01)


if __name__ == "__main__":
    unittest.main()
