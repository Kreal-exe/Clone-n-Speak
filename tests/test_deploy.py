"""The Python modules reach the app and its runtime by mask, not by a list of names."""
import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

OLD_COMMANDS = {"hello", "transcribe", "clone", "synth", "prepare", "analyze", "enhance", "unload",
                "install_accent", "train_voice"}


class Deploy(unittest.TestCase):
    def test_deploy_copies_all_modules(self):
        build = (ROOT / "build.sh").read_text()
        self.assertRegex(build, r'cp\s+"\$ROOT"/Sources/\*\.py\s+"\$RES/py/?"')
        self.assertNotIn("Sources/worker.py", build)
        ov = (ROOT / "Sources" / "OVWorker.m").read_text()
        self.assertNotIn("cns_", ov)
        self.assertIn('@"py"', ov)

    def test_worker_py_unchanged_surface(self):
        spec = importlib.util.spec_from_file_location("worker_deploy", ROOT / "Sources" / "worker.py")
        worker = importlib.util.module_from_spec(spec)
        keep = sys.stdout
        try:
            spec.loader.exec_module(worker)
        finally:
            sys.stdout = keep
        self.assertTrue(OLD_COMMANDS <= set(worker.COMMANDS), OLD_COMMANDS - set(worker.COMMANDS))
        for name in ("_biquad", "_compress", "track_f0", "frames_db", "shape_voice", "load_mono", "write_wav"):
            self.assertTrue(callable(getattr(worker, name)), name)


if __name__ == "__main__":
    unittest.main()
