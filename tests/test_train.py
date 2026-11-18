"""Tests for Sources/cns_train.py. No torch / tensorboard: data is fed as lists, Applio is a fake folder of tiny scripts."""
import json
import os
import pathlib
import random
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))

import cns_proto  # noqa: E402
import cns_train as tr  # noqa: E402

try:
    import numpy as np
except ImportError:  # the system Python 3.9 has no numpy: the audio checks are skipped there
    np = None

FIXTURE = HERE / "fixtures" / "train_log.txt"


def lines():
    return FIXTURE.read_text().splitlines()


class ParseTests(unittest.TestCase):
    def test_progress_regex_parses_epoch_step_batch(self):
        got = [tr.parse_progress(l) for l in lines()]
        parsed = [g for g in got if g]
        self.assertGreaterEqual(len(parsed), 2)
        self.assertEqual(tr.parse_progress("v | epoch=3 | step=42 | batch=5/14"), (3, 42, 5, 14))
        self.assertEqual(tr.parse_progress("v | epoch=3 | step=42 | time=x | training_speed=y"), (3, 42, None, None))
        for junk in ("", "Dataset has 1 speakers.", "epoch=abc | step=1", "Using device: mps", None):
            self.assertIsNone(tr.parse_progress(junk))
        self.assertTrue(tr.is_epoch_summary("v | epoch=1 | step=14 | time=now | training_speed=0:00:26"))
        self.assertFalse(tr.is_epoch_summary("v | epoch=1 | step=5 | batch=5/14"))

    def test_progress_fraction_is_monotonic_across_epochs(self):
        f = tr.EpochFraction(total_epoch=2)
        values = []
        for l in lines():
            p = tr.parse_progress(l)
            if p:
                values.append(f.update(p[0], p[2], p[3]))
        self.assertEqual(values, sorted(values))
        self.assertAlmostEqual(values[-1], 1.0)
        self.assertLessEqual(values[0], 0.5)
        f2 = tr.EpochFraction(2)   # Applio's print_every lines (batch=a/b) in between
        mid = [f2.update(1, 7, 14), f2.update(1, 14, 14), f2.update(2, 7, 14), f2.update(2, None, None)]
        self.assertEqual(mid, [0.25, 0.5, 0.75, 1.0])
        # a resumed run (2 epochs already trained, 4 wanted) starts at 0 and a late line cannot move the bar back
        g = tr.EpochFraction(4, start_epoch=2)
        self.assertAlmostEqual(g.update(3, 7, 14), 0.25)
        self.assertAlmostEqual(g.update(3, 2, 14), 0.25)
        self.assertAlmostEqual(g.update(4, None, None), 1.0)

    def test_batch_defaults_4_and_2_when_memory_tight(self):
        self.assertEqual(tr.default_batch(12.0), 4)
        self.assertEqual(tr.default_batch(11.5), 4)
        self.assertEqual(tr.default_batch(11.4), 2)
        self.assertEqual(tr.default_batch(3.0), 2)
        self.assertEqual(tr.default_batch(None), 4)

    def test_train_command_line_matches_applio_order(self):
        a = tr.train_args("voice", 1, 20, "/w/G.pth", "/w/D.pth", "0", 4, 40000)
        self.assertEqual(len(a), 14)
        self.assertEqual(a[:8], ["voice", "1", "20", "/w/G.pth", "/w/D.pth", "0", "4", "40000"])
        self.assertEqual(a[8], "True")    # save_only_latest
        self.assertEqual(a[9], "True")    # save_every_weights
        self.assertEqual(a[10], "False")  # cache_data_in_gpu
        self.assertEqual(a[11], "False")  # cleanup
        self.assertEqual(a[12], "HiFi-GAN")
        self.assertEqual(a[13], "False")  # checkpointing
        p = tr.preprocess_args("/e", "/d", 40000, 4)
        self.assertEqual((p[4], p[5], p[8]), ("Automatic", "False", "none"))
        x = tr.extract_args("/e", "rmvpe", 4, "0", 40000, "contentvec")
        self.assertEqual((x[3], x[-1]), ("0", "2"))

    def test_dataset_name_slug_rejects_path_chars(self):
        for bad in ("../x", "a/b", "", " a", "a b", "a;rm", ".hidden", "x" * 65, None, "name\n"):
            with self.assertRaises(tr.TrainError, msg=repr(bad)):
                tr.slug(bad)
        self.assertEqual(tr.slug("my_voice-2"), "my_voice-2")


class WatchdogTests(unittest.TestCase):
    def test_watchdog_kills_child_when_no_step_for_120s(self):
        class Clock:
            t = 0.0

            def __call__(self):
                Clock.t += 50.0   # every look at the clock is 50 "seconds" later
                return Clock.t

        wd = cns_proto.Watchdog(tr.TRAIN_WATCHDOG_S, lambda: None, clock=Clock())
        started = time.time()
        procs = []

        def popen(*a, **k):
            p = subprocess.Popen(*a, **k)
            procs.append(p)
            return p

        with self.assertRaises(tr.TrainError) as cm:
            tr.run_child(["/bin/sleep", "30"], dict(os.environ), None, lambda l: None, watchdog=wd, popen=popen)
        self.assertIn("Stalled", str(cm.exception))
        self.assertLess(time.time() - started, 10)
        self.assertIsNotNone(procs[0].poll())


def fake_applio(base, train_sleep=0):
    """A fake engine: scripts with Applio's names that make the files the real ones make."""
    applio = pathlib.Path(base) / "applio"
    for rel, body in {
        "rvc/train/preprocess/preprocess.py": "import os,sys\nos.makedirs(os.path.join(sys.argv[1],'sliced_audios'),exist_ok=True)\nprint('pre ok')\n",
        "rvc/train/extract/extract.py": "import os,sys\nos.makedirs(os.path.join(sys.argv[1],'extracted'),exist_ok=True)\nprint('ext ok')\n",
        "rvc/train/process/extract_index.py": "import os,sys\nopen(os.path.join(sys.argv[1],os.path.basename(sys.argv[1])+'.index'),'w').write('idx')\nprint('idx ok')\n",
        "rvc/train/train.py": (
            "import os,sys,time\n"
            "name,total,exp=sys.argv[1],int(sys.argv[3]),os.path.join(os.environ['APPLIO_LOGS_DIR'],sys.argv[1])\n"
            "assert len(sys.argv)==15, sys.argv\n"
            "os.makedirs(exp,exist_ok=True)\nstep=0\nopen(os.path.join(exp,'pid'),'w').write(str(os.getpid()))\n"
            "for e in range(1,total+1):\n"
            "    for b in (7,14):\n"
            "        step+=7\n        print('%s | epoch=%d | step=%d | batch=%d/14'%(name,e,step,b),flush=True)\n"
            "    print('%s | epoch=%d | step=%d | time=t | training_speed=s'%(name,e,step),flush=True)\n"
            "    open(os.path.join(exp,'G_2333333.pth'),'w').write('g'); open(os.path.join(exp,'D_2333333.pth'),'w').write('d')\n"
            "    open(os.path.join(exp,'%s_%de_%ds.pth'%(name,e,step)),'w').write('w%d'%e)\n"
            "    open(os.path.join(os.environ['TMPDIR'],'scratch'),'w').write('x')\n"
            "    time.sleep(@SLEEP@)\n").replace("@SLEEP@", str(train_sleep)),
    }.items():
        p = applio / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
    return applio


def make_world(train_sleep=0):
    d = tempfile.mkdtemp()
    base = pathlib.Path(d)
    applio = fake_applio(base, train_sleep)
    weights = base / "weights" / "pretraineds" / "hifi-gan"
    weights.mkdir(parents=True)
    (weights / "f0G40k.pth").write_text("g")
    (weights / "f0D40k.pth").write_text("d")
    (base / "ds").mkdir()
    (base / "work").mkdir()
    (base / "training").mkdir()
    req = {"python": sys.executable, "applio": str(applio), "training_dir": str(base / "training"),
           "weights_dir": str(base / "weights"), "models_dir": str(base / "models"), "work_dir": str(base / "work"),
           "name": "voice", "dataset": str(base / "ds"), "sample_rate": 40000, "total_epoch": 2, "batch_size": 4,
           "sandbox": False}
    return base, req


def run_cli(command, req, signal_after=None, timeout=60, sandbox=False):
    env = dict(os.environ)
    if not sandbox:
        env["CNS_TRAIN_NO_SANDBOX"] = "1"   # the fake engine is not what the sandbox tests are about
    p = subprocess.Popen([sys.executable, str(HERE.parent / "Sources" / "cns_train.py"), command], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    p.stdin.write(json.dumps(req) + "\n")
    p.stdin.close()
    events = []
    if signal_after:
        for line in p.stdout:
            ev = cns_proto.parse_event_line(line)
            if ev:
                events.append(ev)
            if signal_after(ev):
                p.send_signal(signal.SIGTERM)
                break
    rest = p.stdout.read()
    err = p.stderr.read()
    p.wait(timeout=timeout)
    events += [e for e in (cns_proto.parse_event_line(l) for l in rest.splitlines()) if e]
    return p.returncode, events, err


class RunTests(unittest.TestCase):
    def test_full_run_exports_and_reports_progress(self):
        base, req = make_world()
        code, events, err = run_cli("run", req)
        self.assertEqual(code, 0, err)
        result = [e for e in events if e["event"] == "result"][0]["data"]
        out = base / "models" / "voice"
        self.assertEqual(sorted(os.path.basename(p) for p in result["outputs"]), ["voice.index", "voice.pth"])
        self.assertEqual((out / "voice.pth").read_text(), "w2")  # the last epoch
        self.assertTrue((out / "meta.json").exists())
        prog = [e["value"] for e in events if e["event"] == "progress"]
        self.assertEqual(prog, sorted(prog))
        self.assertAlmostEqual(prog[-1], 1.0)
        self.assertEqual(list((base / "work").iterdir()), [])

    def test_stop_keeps_resumable_workspace(self):
        base, req = make_world(train_sleep=30)
        started = time.time()
        code, events, err = run_cli("run", req, signal_after=lambda ev: bool(ev and ev["event"] == "progress" and ev["value"] > 0.2))
        self.assertLess(time.time() - started, 20)
        exp = base / "training" / "voice"
        self.assertTrue(exp.is_dir())
        self.assertTrue((exp / "G_2333333.pth").exists())
        self.assertEqual(list((base / "work").iterdir()), [])
        pid = int((exp / "pid").read_text())
        time.sleep(0.5)
        with self.assertRaises(ProcessLookupError):   # the child did not outlive the wrapper
            os.kill(pid, 0)

    def test_work_folder_must_not_hold_kept_folders(self):
        base, req = make_world()
        req["work_dir"] = str(base)   # contains training, dataset and models
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)
        self.assertIn("work folder", [e for e in events if e["event"] == "error"][0]["msg"])
        self.assertTrue((base / "ds").is_dir())

    def test_export_refuses_to_overwrite_a_voice(self):
        base, req = make_world()
        self.assertEqual(run_cli("run", req)[0], 0)
        shutil_rmtree(base / "training")
        (base / "training").mkdir()
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)
        self.assertIn("already exists", [e for e in events if e["event"] == "error"][0]["msg"])
        req["overwrite"] = True
        self.assertEqual(run_cli("run", req)[0], 0)

    def test_sandbox_cannot_be_disabled_by_the_request(self):
        if not os.path.exists("/usr/bin/sandbox-exec"):
            self.skipTest("no sandbox-exec")
        base, req = make_world()
        req["sandbox"] = False
        trainer = tr.Trainer(req)
        self.assertEqual(trainer._argv(["x"])[0], "/usr/bin/sandbox-exec") if "CNS_TRAIN_NO_SANDBOX" not in os.environ else None

    def test_missing_sandbox_tool_is_an_error_not_an_unsandboxed_run(self):
        base, req = make_world()
        trainer = tr.Trainer(req)
        import cns_engines as eng
        old = eng.SANDBOX_EXEC
        eng.SANDBOX_EXEC = "/nonexistent/sandbox-exec"
        os.environ.pop("CNS_TRAIN_NO_SANDBOX", None)
        try:
            with self.assertRaises(tr.TrainError):
                trainer._argv(["x"])
        finally:
            eng.SANDBOX_EXEC = old

    def test_no_second_sandbox_when_the_app_already_runs_it(self):
        base, req = make_world()
        trainer = tr.Trainer(req)
        os.environ.pop("CNS_TRAIN_NO_SANDBOX", None)
        import cns_engines as eng
        good = eng.sandbox_file()
        os.environ["CNS_SANDBOXED"] = "1"
        try:
            # the bare variable is not trusted: the file must be the bundled engine.sb
            self.assertEqual(trainer._argv(["x"])[0], "/usr/bin/sandbox-exec")
            os.environ["CNS_SANDBOX_FILE"] = "/etc/hosts"
            self.assertEqual(trainer._argv(["x"])[0], "/usr/bin/sandbox-exec")
            os.environ["CNS_SANDBOX_FILE"] = good
            self.assertEqual(trainer._argv(["x"])[1:], ["x"])
        finally:
            os.environ.pop("CNS_SANDBOXED", None)
            os.environ.pop("CNS_SANDBOX_FILE", None)

    def test_resume_requires_checkpoints(self):
        base, req = make_world()
        req.update(resume=True, total_epoch=4)
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)
        self.assertIn(tr.NOTHING_TO_CONTINUE, [e for e in events if e["event"] == "error"][0]["msg"])
        # a folder with only weights (no G_/D_) cannot be continued either
        (base / "training" / "voice").mkdir()
        (base / "training" / "voice" / "voice_1e_14s.pth").write_text("w")
        code, events, _ = run_cli("run", req)
        self.assertIn(tr.NOTHING_TO_CONTINUE, [e for e in events if e["event"] == "error"][0]["msg"])

    def test_resume_continues_from_reached_epoch(self):
        base, req = make_world()
        req["total_epoch"] = 2
        self.assertEqual(run_cli("run", req)[0], 0)
        req.update(resume=True, total_epoch=3, overwrite=True)
        code, events, err = run_cli("run", req)
        self.assertEqual(code, 0, err)
        # the fake train.py counts from 1 again, but the wrapper starts the bar at 0 for the one epoch left
        prog = [e["value"] for e in events if e["event"] == "progress"]
        self.assertEqual(prog, sorted(prog))
        # not enough new epochs asked for
        req["total_epoch"] = 2
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)

    def test_fresh_run_refuses_to_overwrite_progress(self):
        base, req = make_world()
        self.assertEqual(run_cli("run", req)[0], 0)
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)

    def test_clean_removes_only_G_D_checkpoints(self):
        base, req = make_world()
        exp = base / "training" / "voice"
        exp.mkdir()
        for n in ("G_2333333.pth", "D_2333333.pth", "G_100.pth", "voice_2e_28s.pth", "voice.index", "G_x.pth",
                  "config.json", "G_100.pth.bak"):
            (exp / n).write_text("x" * 10)
        (exp / "eval").mkdir()
        (exp / "eval" / "G_5.pth").write_text("keep")
        code, events, err = run_cli("clean", {"name": "voice", "applio": str(base / "applio"), "python": sys.executable,
                                              "training_dir": str(base / "training"), "weights_dir": str(base / "weights")})
        self.assertEqual(code, 0, err)
        self.assertEqual(sorted(os.listdir(exp)), ["G_100.pth.bak", "G_x.pth", "config.json", "eval", "voice.index", "voice_2e_28s.pth"])
        self.assertTrue((exp / "eval" / "G_5.pth").exists())
        self.assertEqual([e for e in events if e["event"] == "result"][0]["data"]["freed_bytes"], 30)

    def test_missing_training_base_is_a_clear_error(self):
        base, req = make_world()
        os.remove(base / "weights" / "pretraineds" / "hifi-gan" / "f0G40k.pth")
        code, events, _ = run_cli("run", req)
        self.assertEqual(code, 1)
        self.assertIn("not installed", [e for e in events if e["event"] == "error"][0]["msg"])


@unittest.skipUnless(os.path.exists("/usr/bin/sandbox-exec"), "needs macOS sandbox-exec")
class SandboxProfileTests(unittest.TestCase):
    def test_writes_outside_the_allowed_roots_fail(self):
        root = tempfile.mkdtemp()
        prof = tr.train_profile([root])
        elsewhere = "/tmp/cns-train-probe-%d" % random.randrange(10 ** 9)
        ok = os.path.join(root, "ok")
        r = subprocess.run(["/usr/bin/sandbox-exec", "-p", prof, "/bin/sh", "-c", "echo x > '%s'; echo y > '%s'" % (ok, elsewhere)],
                           capture_output=True, text=True)
        self.assertTrue(os.path.exists(ok))
        self.assertFalse(os.path.exists(elsewhere))
        self.assertNotEqual(r.returncode, 0)

    def test_no_ip_traffic(self):
        import socket
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        code = "import socket,sys\ntry:\n socket.create_connection(('127.0.0.1',%d),2)\n print('connected')\nexcept OSError:\n print('blocked')" % port
        r = subprocess.run(["/usr/bin/sandbox-exec", "-p", tr.train_profile([tempfile.mkdtemp()]), sys.executable, "-c", code],
                           capture_output=True, text=True)
        srv.close()
        self.assertIn("blocked", r.stdout)


def shutil_rmtree(p):
    import shutil
    shutil.rmtree(p)


class DetectorTests(unittest.TestCase):
    def feed(self, det, series):
        for i, (m, g) in enumerate(series, 1):
            det.update(i, m, g)
        return det

    def test_overtrain_detector_u_curve_flags_after_patience(self):
        det = tr.OvertrainDetector(patience=10)
        series = [(30 - e, 60 - 2 * e) for e in range(1, 21)]            # falls for 20 epochs
        series += [(10 + 0.8 * k, 20 + 1.6 * k) for k in range(1, 31)]   # then climbs
        states = []
        for i, (m, g) in enumerate(series, 1):
            states.append(det.update(i, m, g))
        self.assertEqual(states[19], "improving")
        first = states.index("overtrained") + 1
        self.assertGreater(first, 20 + 10 - 1)   # not before the patience ran out
        self.assertLess(first, 20 + 30)
        self.assertEqual(det.state, "overtrained")
        self.assertIn(det.best_epoch, (19, 20, 21))

    def test_plateau_before_overtrained(self):
        det = tr.OvertrainDetector(patience=5)
        self.feed(det, [(20 - e, 40 - e) for e in range(1, 11)] + [(10.0, 30.0)] * 25)
        self.assertEqual(det.state, "plateau")

    def test_detector_never_flags_decreasing_or_noisy_decreasing(self):
        det = tr.OvertrainDetector(patience=10)
        for i in range(1, 80):
            det.update(i, 40 - 0.3 * i, 80 - 0.6 * i)
            self.assertEqual(det.state, "improving")
        rnd = random.Random(7)
        det = tr.OvertrainDetector(patience=10)
        for i in range(1, 80):
            f = 0.97 ** i
            det.update(i, 40 * f * (1 + rnd.uniform(-0.03, 0.03)), 80 * f * (1 + rnd.uniform(-0.03, 0.03)))
            self.assertEqual(det.state, "improving", "epoch %d" % i)

    def test_detector_best_epoch(self):
        det = tr.OvertrainDetector(patience=3)
        self.feed(det, [(10, 20), (8, 16), (6, 12), (7, 13), (9, 15), (11, 18)])
        self.assertEqual(det.best_epoch, 3)
        self.assertEqual(tr.OvertrainDetector.default_patience(40), 10)
        self.assertEqual(tr.OvertrainDetector.default_patience(200), 30)

    def test_export_picks_nearest_weights_file(self):
        d = tempfile.mkdtemp()
        for e, s in ((1, 14), (2, 28), (5, 70)):
            open(os.path.join(d, "v_%de_%ds.pth" % (e, s)), "w").write("x")
        self.assertTrue(tr.nearest_weights(d, "v", 2).endswith("v_2e_28s.pth"))
        self.assertTrue(tr.nearest_weights(d, "v", 4).endswith("v_5e_70s.pth"))
        self.assertIsNone(tr.nearest_weights(d, "other", 2))


@unittest.skipIf(np is None, "numpy is not available")
class ReviewTests(unittest.TestCase):
    SR = 32000

    def speech(self, seconds, seed=0, level=0.2):
        rnd = np.random.RandomState(seed)
        t = np.arange(int(seconds * self.SR)) / self.SR
        env = 0.6 + 0.4 * np.sin(2 * np.pi * (0.7 + 0.1 * seed) * t)
        tone = np.sin(2 * np.pi * (140 + 15 * seed) * t) + 0.5 * np.sin(2 * np.pi * (410 + 20 * seed) * t)
        return (level * env * (0.7 * tone + 0.3 * rnd.randn(len(t)))).astype(np.float32)

    def report(self, arrays, sr=None):
        rows = [("f%d.wav" % i, tr.analyze_samples(a, sr or self.SR)) for i, a in enumerate(arrays)]
        return tr.review_metrics(rows)

    def flags(self, rep, name):
        return [r for r in rep["files"] if r["file"] == name][0]["flags"]

    def test_review_ok_on_clean_speech(self):
        rep = self.report([self.speech(50, seed=i) for i in range(4)])
        self.assertEqual(rep["verdict"], "ok", rep)
        self.assertEqual(rep["dataset_flags"], [])
        self.assertTrue(all(not r["flags"] for r in rep["files"]))
        self.assertAlmostEqual(rep["total_s"], 200, delta=0.5)
        self.assertTrue(any(a["code"] == "more_is_better" for a in rep["advice"]))

    def test_review_flags(self):
        base = [self.speech(40, seed=i) for i in range(3)]
        quiet_gap = self.speech(40, seed=5)
        quiet_gap[int(5 * self.SR):int(21 * self.SR)] = 0  # 40 % silence, one 16 s pause
        clipped = np.clip(self.speech(40, seed=6) * 12, -1, 1)
        dup = base[0].copy()
        short = self.speech(0.5, seed=7)
        quiet = self.speech(40, seed=8, level=0.2 * 10 ** (-8 / 20.0))
        edges = np.concatenate([np.zeros(int(1.5 * self.SR), np.float32), self.speech(30, seed=9), np.zeros(self.SR, np.float32)])
        rep = self.report(base + [quiet_gap, clipped, dup, short, quiet, edges])
        names = {"quiet_gap": "f3.wav", "clipped": "f4.wav", "dup": "f5.wav", "short": "f6.wav", "quiet": "f7.wav", "edges": "f8.wav"}
        self.assertIn("excessive_silence", self.flags(rep, names["quiet_gap"]))
        self.assertIn("long_pause", self.flags(rep, names["quiet_gap"]))
        self.assertIn("clipping", self.flags(rep, names["clipped"]))
        self.assertIn("duplicate", self.flags(rep, names["dup"]))
        self.assertNotIn("duplicate", self.flags(rep, "f0.wav"))
        self.assertIn("too_short", self.flags(rep, names["short"]))
        self.assertIn("level_outlier", self.flags(rep, names["quiet"]))
        self.assertIn("long_edge", self.flags(rep, names["edges"]))
        self.assertNotIn("level_outlier", self.flags(rep, "f0.wav"))
        self.assertIn(rep["verdict"], ("warn", "poor"))
        codes = {a["code"] for a in rep["advice"]}
        self.assertTrue({"excessive_silence", "clipping", "duplicate", "too_short"} <= codes)
        self.assertTrue(all(a["action"] for a in rep["advice"]))

    def test_short_total_and_low_sample_rate(self):
        rep = self.report([self.speech(45, seed=1), self.speech(45, seed=2)])
        self.assertEqual(rep["dataset_flags"], ["short_dataset"])
        self.assertEqual(rep["verdict"], "warn")
        low = tr.analyze_samples(self.speech(200, seed=3)[: 16000 * 200], 16000)
        rep2 = tr.review_metrics([("a.wav", low)])
        self.assertIn("low_sample_rate", rep2["files"][0]["flags"])
        self.assertEqual(tr.review_metrics([("a.wav", {"error": "x"})])["verdict"], "poor")

    def test_identical_decoded_audio_only_is_a_duplicate(self):
        a = self.speech(30, seed=1)
        b = a.copy()
        b[100] += 0.01
        rep = self.report([a, b, a.copy()])
        self.assertEqual([("duplicate" in r["flags"]) for r in rep["files"]], [False, False, True])


if __name__ == "__main__":
    unittest.main()
