import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "Sources"))
import cns_proto  # noqa: E402


class Proto(unittest.TestCase):
    def test_emit_is_one_json_line(self):
        buf = io.StringIO()
        with mock.patch.object(sys, "stdout", buf):
            cns_proto.emit("progress", value=0.5, note="a\nb")
        out = buf.getvalue()
        self.assertEqual(out.count("\n"), 1)
        self.assertEqual(json.loads(out), {"event": "progress", "value": 0.5, "note": "a\nb"})
        self.assertEqual(cns_proto.parse_event_line(out)["event"], "progress")
        self.assertIsNone(cns_proto.parse_event_line("plain log"))
        self.assertIsNone(cns_proto.parse_event_line("{broken"))
        self.assertIsNone(cns_proto.parse_event_line('{"no_event": 1}'))

    def test_print_goes_to_stderr_after_guard(self):
        real, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdout", real), mock.patch.object(sys, "stderr", err):
            old = cns_proto._out
            try:
                cns_proto.install_stdout_guard()
                print("noise from a library")
                cns_proto.result(path="/x")
                self.assertIs(sys.stdout, err)
            finally:
                cns_proto._out = old
        self.assertIn("noise from a library", err.getvalue())
        self.assertNotIn("noise", real.getvalue())
        self.assertEqual(json.loads(real.getvalue())["event"], "result")

    def test_read_request_rejects_garbage(self):
        for raw in ("", "   ", "{nope", "[1,2]"):
            with mock.patch.object(sys, "stdin", io.StringIO(raw)):
                with self.assertRaises(cns_proto.ProtoError) as c:
                    cns_proto.read_request()
            self.assertTrue(str(c.exception).startswith("Bad request: "))
        with mock.patch.object(sys, "stdin", io.StringIO('{"a": 1}')):
            self.assertEqual(cns_proto.read_request(), {"a": 1})

    def test_safe_output_dir_blocks_symlink_and_dotdot(self):
        with tempfile.TemporaryDirectory() as t:
            root = os.path.join(t, "root")
            outside = os.path.join(t, "outside")
            os.makedirs(os.path.join(root, "ok"))
            os.makedirs(outside)
            os.symlink(outside, os.path.join(root, "link"))
            self.assertEqual(cns_proto.safe_output_dir(os.path.join(root, "ok"), [root]),
                             os.path.realpath(os.path.join(root, "ok")))
            for bad in (os.path.join(root, "link"), os.path.join(root, "..", "outside"),
                        os.path.join(root, "ok", "..", "..", "outside"), outside):
                with self.assertRaises(cns_proto.ProtoError) as c:
                    cns_proto.safe_output_dir(bad, [root])
                self.assertEqual(str(c.exception), "Output folder is outside the app folders")
            sib = root + "-evil"  # shares the prefix but is not inside
            os.makedirs(sib)
            with self.assertRaises(cns_proto.ProtoError):
                cns_proto.safe_output_dir(sib, [root])

    def test_check_input_file(self):
        with tempfile.TemporaryDirectory() as t:
            f = os.path.join(t, "a.wav")
            with open(f, "wb") as fh:
                fh.write(b"x")
            self.assertEqual(cns_proto.check_input_file(f), os.path.realpath(f))
            with self.assertRaises(cns_proto.ProtoError):
                cns_proto.check_input_file(t)
            with self.assertRaises(cns_proto.ProtoError):
                cns_proto.check_input_file(os.path.join(t, "missing"))
            with self.assertRaises(cns_proto.ProtoError):
                cns_proto.check_input_file(f, max_bytes=0)
            link = os.path.join(t, "pw")
            os.symlink("/etc/hosts", link)
            with self.assertRaises(cns_proto.ProtoError):
                cns_proto.check_input_file(link)

    def test_progress_map_is_monotonic(self):
        pm = cns_proto.ProgressMap([("preprocess", .05), ("extract", .10), ("train", .85)])
        self.assertAlmostEqual(pm.at("preprocess", 0), 0.0)
        self.assertAlmostEqual(pm.at("preprocess", 1), 0.05)
        self.assertAlmostEqual(pm.at("train", 0.5), 0.575)
        self.assertAlmostEqual(pm.at("train", 1), 1.0)
        self.assertAlmostEqual(pm.at("train", 7), 1.0)  # clamped
        self.assertAlmostEqual(pm.at("extract", 0.2), 1.0)  # never goes back
        pm2 = cns_proto.ProgressMap([("a", 1), ("b", 3)])
        vals = [pm2.at("a", 0.5), pm2.at("a", 0.2), pm2.at("b", 0.0), pm2.at("b", 0.5), pm2.at("a", 1)]
        self.assertEqual(vals, sorted(vals))
        with self.assertRaises(cns_proto.ProtoError):
            pm2.at("nope", 0)

    def test_watchdog_fires_once_after_timeout_and_poke_resets(self):
        now = [100.0]
        fired = []
        wd = cns_proto.Watchdog(10, lambda: fired.append(1), clock=lambda: now[0])
        self.assertFalse(wd.check())
        now[0] += 9
        self.assertFalse(wd.check())
        wd.poke()
        now[0] += 9
        self.assertFalse(wd.check())
        now[0] += 2
        self.assertTrue(wd.check())
        self.assertFalse(wd.check())
        self.assertEqual(fired, [1])


if __name__ == "__main__":
    unittest.main()
