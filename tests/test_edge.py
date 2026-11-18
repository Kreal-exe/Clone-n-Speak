"""Tests for Sources/cns_edge.py (Edge TTS). The edge_tts module and afconvert are fakes; no network."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))

import cns_net  # noqa: E402
import cns_edge as edge  # noqa: E402

VOICES = [{"ShortName": "uk-UA-OstapNeural", "Locale": "uk-UA", "Gender": "Male", "FriendlyName": "Microsoft Ostap",
           "Name": "x", "Status": "GA"},
          {"ShortName": "en-US-AriaNeural", "Locale": "en-US", "Gender": "Female", "FriendlyName": "Microsoft Aria"}]


def fake_module(log):
    m = types.ModuleType("edge_tts")

    class Communicate:
        def __init__(self, text, voice, rate="+0%", pitch="+0Hz", volume="+0%"):
            log.append(("communicate", text, voice, rate, pitch, volume))

        async def save(self, path):
            with open(path, "wb") as f:
                f.write(b"ID3fake")

    async def list_voices():
        log.append(("list_voices",))
        return VOICES

    m.Communicate, m.list_voices = Communicate, list_voices
    return m


def fake_afconvert(cmd, **kw):
    with open(cmd[-1], "wb") as f:
        f.write(b"RIFF....WAVE")
    return subprocess.CompletedProcess(cmd, 0, "", "")


class EdgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "outputs")
        self.work = os.path.join(self.tmp.name, "work")
        self.root = os.path.join(self.tmp.name, "engines")
        self.log = []
        p = mock.patch.dict(sys.modules, {"edge_tts": fake_module(self.log)})
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch.dict(os.environ, {}, clear=False)
        p.start()
        self.addCleanup(p.stop)
        os.environ.pop("OV_OFFLINE", None)

    def req(self, **kw):
        r = {"text": "Hello", "voice": "en-US-AriaNeural", "outputs_dir": self.out, "work_dir": self.work,
             "out_name": "hello", "root": self.root}
        r.update(kw)
        return r

    def test_offline_blocks_edge(self):
        os.environ["OV_OFFLINE"] = "1"
        for call in (lambda: edge.synth(self.req()), lambda: edge.voices(self.req())):
            with self.assertRaises(cns_net.OfflineError) as cm:
                call()
            self.assertIn("Settings", str(cm.exception))
        self.assertEqual(self.log, [])
        self.assertEqual(edge.main(["voices"]), 1)

    def test_edge_text_limit_and_empty(self):
        with mock.patch.object(edge.subprocess, "run", fake_afconvert):
            for t in ("", "   \n", None):
                with self.assertRaises(edge.EdgeError):
                    edge.synth(self.req(text=t))
            with self.assertRaises(edge.EdgeError):
                edge.synth(self.req(text="a" * 20001))
            self.assertEqual(self.log, [])
            res = edge.synth(self.req(text="a" * 20000))
        self.assertTrue(os.path.isfile(res["outputs"][0]))

    def test_rejects_bad_voice_and_settings(self):
        for kw in ({"voice": ""}, {"voice": "../x"}, {"rate": "fast"}, {"pitch": "+5"}, {"volume": "+1000%"}):
            with self.assertRaises(edge.EdgeError):
                edge.synth(self.req(**kw))
        self.assertEqual(self.log, [])

    def test_edge_output_is_wav_in_outputs_dir(self):
        calls = []

        def conv(cmd, **kw):
            calls.append(cmd)
            return fake_afconvert(cmd, **kw)
        with mock.patch.object(edge.subprocess, "run", conv):
            res = edge.synth(self.req(voice="uk-UA-OstapNeural", rate="+10%", pitch="-5Hz", volume="-20%",
                                      out_name="../../evil name.mp3"))
        out = res["outputs"][0]
        self.assertEqual(os.path.dirname(out), self.out)
        self.assertEqual(os.path.basename(out), "edge-evil-name.wav")
        self.assertEqual(self.log[0], ("communicate", "Hello", "uk-UA-OstapNeural", "+10%", "-5Hz", "-20%"))
        cmd = calls[0]
        self.assertEqual(cmd[0], "/usr/bin/afconvert")
        self.assertEqual(cmd[cmd.index("-d") + 1], "LEI16@24000")
        self.assertEqual(os.path.dirname(cmd[-2]), self.work)   # the mp3 lives in work_dir
        with open(out, "rb") as f:
            self.assertEqual(f.read(4), b"RIFF")

    def test_edge_voices_cache_ttl(self):
        now = 1_000_000.0
        res = edge.voices(self.req(), now=now)
        self.assertFalse(res["cached"])
        self.assertEqual([v["ShortName"] for v in res["voices"]], ["uk-UA-OstapNeural", "en-US-AriaNeural"])
        self.assertEqual(set(res["voices"][0]), {"ShortName", "Locale", "Gender", "FriendlyName"})
        self.assertTrue(os.path.isfile(os.path.join(self.root, "edge", "voices.json")))
        res = edge.voices(self.req(), now=now + 6 * 86400)
        self.assertTrue(res["cached"])
        self.assertEqual(self.log.count(("list_voices",)), 1)
        res = edge.voices(self.req(), now=now + 7 * 86400 + 1)
        self.assertFalse(res["cached"])
        self.assertEqual(self.log.count(("list_voices",)), 2)

    def test_corrupt_cache_is_refetched(self):
        os.makedirs(os.path.join(self.root, "edge"))
        with open(os.path.join(self.root, "edge", "voices.json"), "w") as f:
            f.write("{nope")
        self.assertFalse(edge.voices(self.req())["cached"])

    def test_missing_package_message(self):
        with mock.patch.dict(sys.modules, {"edge_tts": None}):
            with self.assertRaises(edge.EdgeError) as cm:
                edge.synth(self.req())
        self.assertIn("not installed", str(cm.exception))

    def test_cli_offline_reports_error_event(self):
        env = dict(os.environ, OV_OFFLINE="1")
        r = subprocess.run([sys.executable, str(HERE.parent / "Sources" / "cns_edge.py"), "synth"],
                           input=json.dumps(self.req()) + "\n", capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 1)
        ev = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(ev["event"], "error")
        self.assertIn("Settings", ev["msg"])


if __name__ == "__main__":
    unittest.main()
