"""Tests for Sources/cns_ytdl.py (YouTube import). The yt-dlp process is replaced by a fake runner; no network."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))

import cns_net  # noqa: E402
import cns_proto  # noqa: E402
import cns_ytdl as yt  # noqa: E402

VID = "dQw4w9WgXcQ"
GOOD = "https://www.youtube.com/watch?v=" + VID


class FakeRun:
    def __init__(self, info=None, info_code=0, dl_code=0, make_file=True):
        self.info = {"title": "Clip", "duration": 60, "is_live": False} if info is None else info
        self.info_code, self.dl_code, self.make_file = info_code, dl_code, make_file
        self.calls = []

    def __call__(self, argv, timeout, env):
        self.calls.append((argv, timeout, env))
        if "--dump-single-json" in argv:
            return subprocess.CompletedProcess(argv, self.info_code, json.dumps(self.info),
                                               "ERROR: gone" if self.info_code else "")
        if self.make_file and not self.dl_code:
            out = argv[argv.index("-o") + 1].replace("%(ext)s", "wav")
            with open(out, "wb") as f:
                f.write(b"RIFF")
        return subprocess.CompletedProcess(argv, self.dl_code, "", "ERROR: boom" if self.dl_code else "")


class YtTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "outputs")
        self.work = os.path.join(self.tmp.name, "work")
        os.makedirs(self.out)
        os.makedirs(self.work)
        p = mock.patch.object(yt, "find_ffmpeg", return_value="/opt/homebrew/bin/ffmpeg")
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch.dict(os.environ, {}, clear=False)
        p.start()
        self.addCleanup(p.stop)
        os.environ.pop("OV_OFFLINE", None)

    def req(self, **kw):
        r = {"url": GOOD, "consent": True, "dest_dir": self.out, "max_minutes": 20, "work_dir": self.work,
             "outputs_dir": self.out}
        r.update(kw)
        return r

    def test_youtube_requires_consent(self):
        for c in (False, None, "true", 1):
            run = FakeRun()
            with self.assertRaises(yt.YtError) as cm:
                yt.fetch(self.req(consent=c), run)
            self.assertIn("rights to this recording and the speaker", str(cm.exception))
            self.assertEqual(run.calls, [])

    def test_url_whitelist_and_single_video(self):
        bad = ["https://www.youtube.com/playlist?list=PLabc", "https://www.youtube.com/@somechannel",
               "https://www.youtube.com/channel/UCabc", "https://evil.com/watch?v=" + VID,
               "https://www.youtube.com.evil.com/watch?v=" + VID, "https://evil.com/?u=youtube.com/watch?v=" + VID,
               "javascript:alert(1)", "file:///etc/passwd", "/Users/me/a.wav", "http://www.youtube.com/watch?v=" + VID,
               "https://www.youtube.com/watch?v=short", "https://www.youtube.com/watch?v=" + VID + "x",
               "https://www.youtube.com/watch?v=" + VID + "&v=" + VID, "https://www.youtube.com/watch",
               "https://user@www.youtube.com/watch?v=" + VID, "https://www.youtube.com:8443/watch?v=" + VID,
               "https://youtu.be/", "https://youtu.be/short", "https://youtu.be/" + VID + "/extra", "",
               "https://www.youtube.com/watch?v=%2e%2e%2f%2e%2e%2fetc", None, 5]
        for u in bad:
            with self.subTest(url=u):
                run = FakeRun()
                with self.assertRaises(yt.YtError):
                    yt.fetch(self.req(url=u), run)
                self.assertEqual(run.calls, [])
        ok = {GOOD + "&list=PL123&index=4&t=30": GOOD, "https://youtu.be/%s?list=PLx&si=abc" % VID: GOOD,
              "https://music.youtube.com/watch?v=%s&list=RDx" % VID: "https://music.youtube.com/watch?v=" + VID}
        for u, canon in ok.items():
            with self.subTest(url=u):
                self.assertEqual(yt.parse_url(u), (VID, canon))
        run = FakeRun()
        yt.fetch(self.req(url=GOOD + "&list=PL123&index=2"), run)
        for argv, _, _ in run.calls:
            self.assertEqual(argv[-1], GOOD)
            self.assertNotIn("list=", " ".join(argv))

    def test_length_limit_before_download(self):
        run = FakeRun(info={"title": "Long", "duration": 45 * 60})
        with self.assertRaises(yt.YtError) as cm:
            yt.fetch(self.req(max_minutes=20), run)
        self.assertEqual(str(cm.exception), "Too long: 45 min, limit 20 min")
        self.assertEqual(len(run.calls), 1)   # only the info call
        self.assertEqual(os.listdir(self.out), [])

    def test_live_stream_refused(self):
        for info in ({"duration": 60, "is_live": True}, {"duration": None, "live_status": "is_live"},
                     {"duration": 60, "live_status": "is_upcoming"}):
            run = FakeRun(info=info)
            with self.assertRaises(yt.YtError) as cm:
                yt.fetch(self.req(), run)
            self.assertIn("Live", str(cm.exception))
            self.assertEqual(len(run.calls), 1)

    def test_playlist_answer_refused(self):
        with self.assertRaises(yt.YtError):
            yt.fetch(self.req(), FakeRun(info={"_type": "playlist", "duration": 60}))

    def test_missing_ffmpeg_message(self):
        run = FakeRun()
        with mock.patch.object(yt, "find_ffmpeg", return_value=None):
            with self.assertRaises(yt.YtError) as cm:
                yt.fetch(self.req(), run)
        self.assertEqual(str(cm.exception), "Install ffmpeg first (brew install ffmpeg)")
        self.assertEqual(run.calls, [])

    def test_ytdlp_argv_has_no_shell_cookies_exec(self):
        run = FakeRun()
        res = yt.fetch(self.req(), run)
        self.assertEqual(len(run.calls), 2)
        for argv, _, env in run.calls:
            self.assertIsInstance(argv, list)
            self.assertIn("--ignore-config", argv)
            self.assertIn("--no-playlist", argv)
            self.assertIn("--no-exec", argv)
            self.assertIn("--no-plugin-dirs", argv)
            self.assertNotIn("cookies", " ".join(argv).lower())
            self.assertNotIn("--exec", argv)
            self.assertEqual(argv[-2:], ["--", GOOD])
            self.assertEqual(env["PATH"], "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        self.assertIn("--dump-single-json", run.calls[0][0])
        dl = run.calls[1][0]
        self.assertEqual(dl[dl.index("--audio-format") + 1], "wav")
        self.assertIn("-x", dl)
        real = os.path.realpath(self.out)
        self.assertEqual(dl[dl.index("-o") + 1], os.path.join(real, "yt-%s.%%(ext)s" % VID))
        self.assertEqual(res["outputs"], [os.path.join(real, "yt-%s.wav" % VID)])
        self.assertEqual((res["title"], res["duration"]), ("Clip", 60.0))

    def test_no_shell_in_source(self):
        src = (HERE.parent / "Sources" / "cns_ytdl.py").read_text()
        self.assertNotIn("shell=True", src)
        self.assertNotIn("os.system", src)

    def test_title_is_trimmed_and_cleaned(self):
        res = yt.fetch(self.req(), FakeRun(info={"title": "A\nB" + "x" * 500, "duration": 5}))
        self.assertLessEqual(len(res["title"]), yt.TITLE_LIMIT)
        self.assertNotIn("\n", res["title"])

    def test_dest_dir_must_be_inside_app_folders(self):
        run = FakeRun()
        for bad in ("/etc", os.path.expanduser("~/Desktop"), os.path.join(self.out, "..", "..")):
            with self.assertRaises(cns_proto.ProtoError):
                yt.fetch(self.req(dest_dir=bad), run)
        self.assertEqual(run.calls, [])

    def test_failed_download_gives_error(self):
        with self.assertRaises(yt.YtError) as cm:
            yt.fetch(self.req(), FakeRun(dl_code=1))
        self.assertIn("Download failed", str(cm.exception))
        with self.assertRaises(yt.YtError):
            yt.fetch(self.req(), FakeRun(info_code=1))

    def test_offline_blocks_youtube(self):
        os.environ["OV_OFFLINE"] = "1"
        run = FakeRun()
        with self.assertRaises(cns_net.OfflineError) as cm:
            yt.fetch(self.req(), run)
        self.assertIn("Settings", str(cm.exception))
        self.assertEqual(run.calls, [])

    def test_cli_offline_reports_error_event(self):
        env = dict(os.environ, OV_OFFLINE="1")
        r = subprocess.run([sys.executable, str(HERE.parent / "Sources" / "cns_ytdl.py"), "fetch"],
                           input=json.dumps(self.req()) + "\n", capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 1)
        ev = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(ev["event"], "error")
        self.assertIn("Settings", ev["msg"])

    def test_timeout_kills_process_group(self):
        marker = os.path.join(self.tmp.name, "pid")
        code = ("import subprocess,sys,time; p=subprocess.Popen(['/bin/sleep','60']); "
                "open(sys.argv[1],'w').write(str(p.pid)); time.sleep(60)")
        with self.assertRaises(subprocess.TimeoutExpired):
            yt._run([sys.executable, "-c", code, marker], 2, {"PATH": "/usr/bin:/bin"})
        time.sleep(0.3)
        with open(marker) as f:
            pid = int(f.read())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
