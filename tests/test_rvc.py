"""Tests for Sources/cns_rvc.py and Sources/cns_seedvc.py. No torch needed except the pickle-trap test (skipped without it);
no network: a fake opener, fake converters, tiny generated WAV files."""
import contextlib
import io
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
import zipfile
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))

import cns_engines  # noqa: E402
import cns_proto  # noqa: E402
import cns_rvc as rvc  # noqa: E402
import cns_seedvc as seedvc  # noqa: E402

FIX = HERE / "fixtures" / "rvc_ckpt"
try:
    import torch  # noqa: F401
    HAVE_TORCH = True
except ImportError:
    HAVE_TORCH = False


def make_wav(path, seconds=1.0, rate=16000, channels=1, amp=8000, sampwidth=2):
    n = int(rate * seconds)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sampwidth)
        w.setframerate(rate)
        frames = b"".join(struct.pack("<h", amp if (i // 20) % 2 else -amp) * channels for i in range(min(n, 4000)))
        reps = max(1, n // 4000)
        for _ in range(reps):
            w.writeframes(frames)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="cns-rvc-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        patch = mock.patch.dict(os.environ, {"CNS_ALLOWED_ROOTS": str(self.tmp)})   # what the app passes to every process
        patch.start()
        self.addCleanup(patch.stop)


class InferRequest(Tmp):
    def test_infer_request_validation(self):
        ok = rvc.validate_infer_request({})
        self.assertEqual((ok["pitch"], ok["f0_method"], ok["embedder"], ok["export_format"]), (0, "rmvpe", "contentvec", "WAV"))
        for method in ("rmvpe", "crepe", "fcpe"):
            self.assertEqual(rvc.validate_infer_request({"f0_method": method})["f0_method"], method)
        bad = [{"pitch": 25}, {"pitch": -25}, {"pitch": 1.5}, {"pitch": True}, {"pitch": "3"}, {"protect": 0.6}, {"protect": -0.1},
               {"index_rate": 1.1}, {"index_rate": float("nan")}, {"volume_envelope": 2},
               {"formant": {"on": True, "qfrency": 0}}, {"formant": {"timbre": 17}}, {"formant": {"on": "yes"}},
               {"autotune": {"strength": 1.5}}, {"cleanup": {"mode": "loud"}}, {"cleanup": {"strength": 99}},
               {"f0_method": "harvest"}, {"f0_method": "pm"}, {"embedder": "hubert-x"}, {"export_format": "EXE"},
               {"formant": "on"}]
        for req in bad:
            with self.assertRaises(rvc.RvcError, msg=str(req)):
                rvc.validate_infer_request(req)
        edge = rvc.validate_infer_request({"pitch": -24, "protect": 0.5, "index_rate": 0, "formant": {"on": True, "qfrency": 16}})
        self.assertEqual((edge["pitch"], edge["protect"], edge["index_rate"], edge["formant"]["qfrency"]), (-24, 0.5, 0.0, 16.0))

    def test_applio_kwargs_carry_every_setting(self):
        p = rvc.validate_infer_request({"pitch": 3, "f0_method": "fcpe", "autotune": {"on": True, "strength": 0.5},
                                        "cleanup": {"mode": "light", "strength": 10}, "formant": {"on": True}})
        kw = rvc.applio_kwargs(p)
        self.assertEqual((kw["pitch"], kw["f0_method"], kw["f0_autotune"], kw["f0_autotune_strength"]), (3, "fcpe", True, 0.5))
        self.assertEqual((kw["cleanup_mode"], kw["formant_shifting"], kw["sid"]), ("light", True, 0))
        # Applio always writes a WAV; the chosen export format is applied by final_output, never by Applio's converter
        mp3 = rvc.applio_kwargs(rvc.validate_infer_request({"export_format": "mp3"}))
        self.assertEqual(mp3["export_format"], "WAV")

    def test_export_formats_are_encoded_after_the_conversion(self):
        out = self.tmp / "outputs"
        out.mkdir()
        for fmt, ext, codec in (("WAV", ".wav", None), ("MP3", ".mp3", "libmp3lame"), ("FLAC", ".flac", "flac"),
                                ("OGG", ".ogg", "libvorbis"), ("M4A", ".m4a", "aac")):
            with self.subTest(fmt):
                wav = self.tmp / ("p-%s.wav" % fmt)
                make_wav(wav, 1.0)
                calls = []

                def fake_run(cmd, timeout=0):
                    calls.append(cmd)
                    pathlib.Path(cmd[-1]).write_bytes(b"encoded")
                    return subprocess.CompletedProcess(cmd, 0, "", "")

                params = rvc.validate_infer_request({"export_format": fmt})
                with mock.patch.object(rvc, "_tool", lambda n: "/x/" + n):
                    dest = rvc.final_output(str(wav), params, str(out), "voice", str(self.tmp / "work"), run=fake_run)
                self.assertTrue(dest.endswith("voice" + ext) and os.path.isfile(dest))
                if codec:
                    self.assertIn(codec, calls[0])
                    self.assertEqual(open(dest, "rb").read(), b"encoded")
                else:
                    self.assertEqual(calls, [])
                    self.assertFalse(wav.exists())
        # no encoder: a plain error, nothing half-written
        wav = self.tmp / "q.wav"
        make_wav(wav, 1.0)
        with mock.patch.object(rvc, "_tool", lambda n: None):
            with self.assertRaises(rvc.RvcError) as cm:
                rvc.final_output(str(wav), rvc.validate_infer_request({"export_format": "MP3"}), str(out), "v2", str(self.tmp))
        self.assertIn("Choose WAV", str(cm.exception))

    @unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
    def test_real_ffmpeg_encodes_mp3_and_flac(self):
        out = self.tmp / "outputs"
        out.mkdir()
        for fmt in ("MP3", "FLAC", "OGG", "M4A"):
            wav = self.tmp / ("r-%s.wav" % fmt)
            make_wav(wav, 1.0, rate=16000)
            dest = rvc.final_output(str(wav), rvc.validate_infer_request({"export_format": fmt}), str(out), "r", str(self.tmp))
            self.assertGreater(os.path.getsize(dest), 100, fmt)


class Inputs(Tmp):
    """Unwelcome audio: every shape ends in a plan that works or a plain error, before any torch call."""

    CASES = [
        # name, ext, probe, expected action or error substring
        ("mono 16k wav", ".wav", dict(channels=1, rate=16000, seconds=3.0, pcm16=True), "use"),
        ("mono 44.1k wav", ".wav", dict(channels=1, rate=44100, seconds=3.0, pcm16=True), "use"),
        ("stereo wav", ".wav", dict(channels=2, rate=44100, seconds=3.0, pcm16=True), "convert"),
        ("8k wav", ".wav", dict(channels=1, rate=8000, seconds=3.0, pcm16=True), "use"),
        ("96k wav", ".wav", dict(channels=1, rate=96000, seconds=3.0, pcm16=True), "convert"),
        ("24-bit wav", ".wav", dict(channels=1, rate=44100, seconds=3.0, pcm16=False), "convert"),
        ("half a second", ".wav", dict(channels=1, rate=16000, seconds=0.5, pcm16=True), "use"),
        ("30 minutes", ".wav", dict(channels=1, rate=44100, seconds=1800.0, pcm16=True), "use"),
        ("mp3", ".mp3", dict(channels=1, rate=44100, seconds=3.0, pcm16=False), "convert"),
        ("m4a", ".m4a", dict(channels=2, rate=48000, seconds=3.0, pcm16=False), "convert"),
        ("mp4 video", ".mp4", dict(channels=2, rate=44100, seconds=3.0, pcm16=False), "convert"),
        ("empty", ".wav", dict(channels=1, rate=16000, seconds=0.0, pcm16=True), "too short"),
        ("blink", ".wav", dict(channels=1, rate=16000, seconds=0.05, pcm16=True), "too short"),
        ("four hours", ".wav", dict(channels=1, rate=16000, seconds=4 * 3600.0, pcm16=True), "Split it"),
        ("exe", ".exe", dict(channels=1, rate=16000, seconds=3.0, pcm16=True), "not supported"),
    ]

    def test_convert_accepts_formats_and_lengths(self):
        for name, ext, probe, want in self.CASES:
            with self.subTest(name):
                path = "/x/in" + ext
                if want in ("use", "convert"):
                    plan = rvc.plan_prepare_input(path, probe, str(self.tmp))
                    self.assertEqual(plan["action"], want)
                    self.assertLessEqual(plan["rate"] or 0, 48000)
                    if want == "convert":
                        self.assertTrue(plan["dst"].startswith(str(self.tmp)))
                        self.assertNotEqual(plan["dst"], path)
                else:
                    with self.assertRaises(rvc.RvcError) as cm:
                        rvc.plan_prepare_input(path, probe, str(self.tmp))
                    self.assertIn(want, str(cm.exception))

    def test_unknown_probe_still_tries_the_converters(self):
        plan = rvc.plan_prepare_input("/x/odd.opus", None, str(self.tmp))
        self.assertEqual((plan["action"], plan["rate"]), ("convert", None))

    def test_silent_recording_is_refused_with_the_plain_message(self):
        silent = self.tmp / "silent.wav"
        make_wav(silent, 1.0, amp=0)
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.prepare_input(str(silent), str(self.tmp / "w"))
        self.assertEqual(str(cm.exception), "The recording is silent — nothing to convert")
        quiet = self.tmp / "quiet.wav"
        make_wav(quiet, 1.0, amp=10)   # -70 dBFS
        with self.assertRaises(rvc.RvcError):
            rvc.prepare_input(str(quiet), str(self.tmp / "w"))

    def test_plain_wav_is_used_in_place_and_others_go_through_the_converter(self):
        good = self.tmp / "good.wav"
        make_wav(good, 1.0)
        self.assertEqual(rvc.prepare_input(str(good), str(self.tmp / "w")), str(good))
        stereo = self.tmp / "stereo.wav"
        make_wav(stereo, 1.0, rate=44100, channels=2)
        calls = []

        def fake_run(cmd, timeout=0):
            calls.append(cmd)
            make_wav(cmd[-1], 1.0, rate=44100)   # what a converter would have produced
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with mock.patch.object(rvc, "convert_commands", lambda s, d, r: [["conv", s, "-r", str(r), d]]):
            out = rvc.prepare_input(str(stereo), str(self.tmp / "w"), probe=rvc.probe_audio, run=fake_run)
        self.assertTrue(out.endswith("input-0.wav") and os.path.isfile(out))
        self.assertEqual(calls[0][3], "44100")

    def test_converter_failure_and_missing_file_are_plain_errors(self):
        bogus = self.tmp / "bogus.mp3"
        bogus.write_bytes(b"not audio at all")
        with mock.patch.object(rvc, "convert_commands", lambda s, d, r: [["false"]]):
            with self.assertRaises(rvc.RvcError) as cm:
                rvc.prepare_input(str(bogus), str(self.tmp / "w"), probe=lambda p: None,
                                  run=lambda cmd, t=0: subprocess.CompletedProcess(cmd, 1, "", "bad"))
        self.assertIn("Can't read this audio file", str(cm.exception))
        with self.assertRaises(cns_proto.ProtoError):
            rvc.prepare_input(str(self.tmp / "missing.wav"), str(self.tmp / "w"))

    @unittest.skipUnless(os.path.exists("/usr/bin/afconvert"), "needs macOS afconvert")
    def test_real_afconvert_handles_stereo_96k_and_mp3(self):
        st = self.tmp / "st.wav"
        make_wav(st, 1.0, rate=96000, channels=2)
        out = rvc.prepare_input(str(st), str(self.tmp / "w"), 0)
        peak, seconds, rate, ch = rvc.wav_stats(out)
        self.assertEqual((ch, rate), (1, 48000))
        self.assertAlmostEqual(seconds, 1.0, delta=0.05)
        out2 = rvc.prepare_input(str(HERE / "fixtures" / "tone-1s-44k-mono.mp3"), str(self.tmp / "w"), 1)
        self.assertEqual(rvc.wav_stats(out2)[3], 1)
        out3 = rvc.prepare_input(str(HERE / "fixtures" / "tone-video-1s.mp4"), str(self.tmp / "w"), 2)
        self.assertGreater(rvc.wav_stats(out3)[1], 0.5)


class Models(Tmp):
    def test_model_id_is_slug_plus_hash_and_unique(self):
        a, b = "a" * 64, "b" * 64
        self.assertEqual(rvc.model_id("My Voice!", a), "my-voice-aaaaaaaa")
        self.assertNotEqual(rvc.model_id("My Voice!", a), rvc.model_id("My Voice!", b))
        self.assertEqual(rvc.model_id("My Voice!", a), rvc.model_id("My Voice!", a))
        for name in ("../../etc/passwd", "Голос Алисы", "", "   ", "a/b\\c", "x" * 300, "..", "\x00evil"):
            mid = rvc.model_id(name, a)
            self.assertRegex(mid, r"^[a-z0-9-]+-aaaaaaaa$")
            self.assertLess(len(mid), 60)
            self.assertNotIn("..", mid)
        with self.assertRaises(rvc.RvcError):
            rvc.model_id("x", "zz")

    def test_resolve_model_stays_inside_the_models_folder(self):
        models = self.tmp / "models"
        (models / "v-1234abcd").mkdir(parents=True)
        (models / "v-1234abcd" / "v.pth").write_bytes(b"x")
        (models / "v-1234abcd" / "v.index").write_bytes(b"x")
        pth, index, folder = rvc.resolve_model("v-1234abcd", str(models))
        self.assertTrue(pth.endswith("v.pth") and index.endswith("v.index"))
        outside = self.tmp / "elsewhere"
        outside.mkdir()
        (outside / "m.pth").write_bytes(b"x")
        for bad in (str(outside), str(models / ".." / "elsewhere"), "", None, str(models)):
            with self.assertRaises(rvc.RvcError, msg=str(bad)):
                rvc.resolve_model(bad, str(models))
        os.symlink(str(outside), str(models / "link"))
        with self.assertRaises(rvc.RvcError):
            rvc.resolve_model(str(models / "link"), str(models))

    def test_output_outside_roots_refused(self):
        out = self.tmp / "outputs"
        out.mkdir()
        (out / "sub").mkdir()
        self.assertEqual(rvc.output_dir({"outputs_dir": str(out)}), str(out.resolve()))
        self.assertEqual(rvc.output_dir({"outputs_dir": str(out), "output_dir": str(out / "sub")}), str((out / "sub").resolve()))
        for target in ("/tmp", "/etc", str(self.tmp), str(out / ".." / "x"), str(out) + "-evil"):
            with self.assertRaises(rvc.RvcError, msg=target):
                rvc.output_dir({"outputs_dir": str(out), "output_dir": target})
        os.symlink("/tmp", str(out / "escape"))
        with self.assertRaises(rvc.RvcError):
            rvc.output_dir({"outputs_dir": str(out), "output_dir": str(out / "escape")})
        with self.assertRaises(rvc.RvcError):
            rvc.output_dir({})
        # outputs_dir itself must lie inside the roots the app passed
        elsewhere = pathlib.Path(tempfile.mkdtemp(prefix="cns-rvc-else-")).resolve()
        self.addCleanup(shutil.rmtree, elsewhere, True)
        with self.assertRaises(rvc.RvcError):
            rvc.output_dir({"outputs_dir": str(elsewhere)})
        with mock.patch.dict(os.environ, {"CNS_ALLOWED_ROOTS": os.pathsep.join([str(self.tmp), str(elsewhere)])}):
            self.assertEqual(rvc.output_dir({"outputs_dir": str(elsewhere)}), str(elsewhere))
        # a sibling whose name starts like a root is not inside it
        with self.assertRaises(rvc.RvcError):
            rvc.output_dir({"outputs_dir": str(self.tmp) + "-evil"})
        # a hostile file name cannot leave the folder either
        self.assertEqual(rvc.safe_stem("../../etc/passwd.wav"), "passwd")
        self.assertEqual(rvc.safe_stem("/"), "converted")
        self.assertEqual(os.path.dirname(rvc.unique_path(str(out), rvc.safe_stem("../../x"), ".wav")), str(out))

    def test_roots_fallback_without_the_app_env(self):
        env = {k: v for k, v in os.environ.items() if k != "CNS_ALLOWED_ROOTS"}
        eng = self.tmp / "app" / "engines"
        eng.mkdir(parents=True)
        (self.tmp / "app" / "outputs").mkdir()
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(os.environ, {"CNS_ENGINES_ROOT": str(eng)}):
            ok = {"outputs_dir": str(self.tmp / "app" / "outputs")}
            self.assertEqual(rvc.output_dir(ok), str((self.tmp / "app" / "outputs").resolve()))
            work = {"outputs_dir": str(self.tmp / "w" / "o"), "work_dir": str(self.tmp / "w")}
            (self.tmp / "w" / "o").mkdir(parents=True)
            self.assertTrue(rvc.output_dir(work))   # the work dir is allowed too
            for bad in ({"outputs_dir": str(self.tmp)}, {"outputs_dir": "/tmp"}, {"outputs_dir": str(eng)}):
                with self.assertRaises(rvc.RvcError, msg=str(bad)):
                    rvc.output_dir(bad)
            with self.assertRaises(rvc.RvcError):
                rvc.models_root({"models_dir": "/tmp/x"})
            with self.assertRaises(rvc.RvcError):
                rvc.engine_root({"engines_root": "/tmp/x"})
            self.assertEqual(rvc.models_root({}), os.path.join(str(self.tmp / "app"), "rvc", "models"))

    def test_models_and_engines_roots_come_from_the_allowed_roots(self):
        inside = self.tmp / "models"
        self.assertEqual(rvc.models_root({"models_dir": str(inside)}), str(inside))
        for bad in ("/tmp/evil", str(self.tmp) + "-x/models", "/"):
            with self.assertRaises(rvc.RvcError, msg=bad):
                rvc.models_root({"models_dir": bad})
            with self.assertRaises(rvc.RvcError, msg=bad):
                rvc.engine_root({"engines_root": bad})
        with mock.patch.dict(os.environ, {"CNS_RVC_MODELS": "/tmp/evil"}):
            with self.assertRaises(rvc.RvcError):
                rvc.models_root({})


def good_checkpoint(**over):
    ck = {"weight": {"w": 1}, "config": [1, 2, 40000], "sr": "40k", "f0": 1, "version": "v2", "info": "325epoch"}
    ck.update(over)
    return ck


class Checkpoints(Tmp):
    def test_describe_checkpoint_fields(self):
        info = rvc.describe_checkpoint(good_checkpoint(), 55_000_000, "ab" * 32, True)
        self.assertEqual(info, {"version": "v2", "sample_rate": 40000, "f0": True, "epochs": 325, "size_bytes": 55_000_000,
                                "sha256": "ab" * 32, "has_index": True})
        v1 = rvc.describe_checkpoint(good_checkpoint(version="v1", sr="48k", f0=0, info="x"), 1, "c" * 64, False)
        self.assertEqual((v1["version"], v1["sample_rate"], v1["f0"], v1["epochs"], v1["has_index"]), ("v1", 48000, False, None, False))
        for bad in ({"weight": "no"}, {"config": None, "weight": None}, {"version": "v9"}, {"sr": "huge", "config": [1, "x"]}):
            ck = good_checkpoint(**bad)
            if bad == {"config": None, "weight": None}:
                del ck["config"]
            with self.assertRaises(rvc.RvcError, msg=str(bad)):
                rvc.describe_checkpoint(ck, 1, "d" * 64, False)

    def test_container_refuses_non_zip_and_unsafe_members(self):
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.check_pth_container(str(FIX / "not-a-pickle.pth"))
        self.assertEqual(str(cm.exception), "This isn’t a safe voice model file")
        evil = self.tmp / "evil.pth"
        with zipfile.ZipFile(evil, "w") as z:
            z.writestr("archive/data.pkl", b"x")
            z.writestr("../../escape", b"x")
        with self.assertRaises(rvc.RvcError):
            rvc.check_pth_container(str(evil))
        notorch = self.tmp / "zip-without-pickle.pth"
        with zipfile.ZipFile(notorch, "w") as z:
            z.writestr("readme.txt", b"hello")
        with self.assertRaises(rvc.RvcError):
            rvc.check_pth_container(str(notorch))
        empty = self.tmp / "empty.pth"
        empty.write_bytes(b"")
        with self.assertRaises(rvc.RvcError):
            rvc.check_pth_container(str(empty))
        self.assertEqual(rvc.check_pth_container(str(FIX / "pickle-trap.pth")), str(FIX / "pickle-trap.pth"))   # shape only

    @unittest.skipUnless(HAVE_TORCH, "needs torch (runs on the Mac with the pro engines installed)")
    def test_import_refuses_unsafe_pickle(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out):
            with self.assertRaises(rvc.RvcError) as cm:
                rvc.load_checkpoint(str(FIX / "pickle-trap.pth"))
        self.assertEqual(str(cm.exception), "This isn’t a safe voice model file")
        self.assertNotIn("cns-pickle-executed", out.getvalue())   # the payload never ran
        models = self.tmp / "models"
        with contextlib.redirect_stdout(out):
            with self.assertRaises(rvc.RvcError):
                rvc.import_model(str(models), "trap", pth=str(FIX / "pickle-trap.pth"))
        self.assertNotIn("cns-pickle-executed", out.getvalue())
        self.assertEqual([n for n in os.listdir(models)], [])   # nothing half-imported is left
        for name in ("not-a-pickle.pth",):
            with self.assertRaises(rvc.RvcError):
                rvc.import_model(str(models), "x", pth=str(FIX / name))

    @unittest.skipUnless(HAVE_TORCH, "needs torch")
    def test_real_torch_checkpoint_roundtrip(self):
        import torch
        p = self.tmp / "m.pth"
        torch.save(good_checkpoint(weight={"enc_p.w": torch.zeros(2)}), str(p))
        res = rvc.import_model(str(self.tmp / "models"), "Roundtrip", pth=str(p))
        self.assertEqual(res["info"]["sample_rate"], 40000)
        pth, index, folder = rvc.resolve_model(res["id"], str(self.tmp / "models"))
        self.assertEqual(rvc.load_checkpoint(pth)["version"], "v2")


class Indexes(Tmp):
    def test_index_files_need_suffix_size_and_faiss_magic(self):
        for magic in (b"IxF2", b"IwFl", b"IwPQ", b"IHNf", b"IxFI"):
            p = self.tmp / ("ok-%s.index" % magic.decode())
            p.write_bytes(magic + b"\0" * 16)
            self.assertEqual(rvc.check_index_file(str(p)), str(p))
        bad = {"wrong.bin": b"IwFl" + b"\0" * 8, "text.index": b"hello world", "pickle.index": b"\x80\x04\x95abcd",
               "short.index": b"Iw", "empty.index": b"", "lower.index": b"iwfl0000", "ctrl.index": b"I\0\0\0rest"}
        for name, body in bad.items():
            (self.tmp / name).write_bytes(body)
            with self.assertRaises(rvc.RvcError, msg=name):
                rvc.check_index_file(str(self.tmp / name))
        big = self.tmp / "big.index"
        big.write_bytes(b"IwFl" + b"\0" * 64)
        with mock.patch.object(rvc, "MAX_INDEX_BYTES", 32):
            with self.assertRaises(rvc.RvcError) as cm:
                rvc.check_index_file(str(big))
        self.assertIn("1 GB", str(cm.exception))

    def test_import_refuses_bad_index_loose_and_in_zip(self):
        pth = self.tmp / "m.pth"
        with zipfile.ZipFile(pth, "w") as z:
            z.writestr("archive/data.pkl", b"w")
        bad = self.tmp / "bad.index"
        bad.write_bytes(b"not faiss at all")
        loader = lambda p: good_checkpoint()
        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(self.tmp / "models"), "x", pth=str(pth), index=str(bad), loader=loader)
        notindex = self.tmp / "idx.bin"
        notindex.write_bytes(b"IwFl" + b"\0" * 8)
        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(self.tmp / "models"), "x", pth=str(pth), index=str(notindex), loader=loader)
        zp = self.tmp / "m.zip"
        with zipfile.ZipFile(zp, "w") as z:
            z.writestr("a/m.pth", b"w")
            z.writestr("a/m.index", b"<html>nope</html>")
        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(self.tmp / "models"), "x", zip_path=str(zp), loader=loader)
        self.assertEqual(os.listdir(self.tmp / "models"), [])
        with zipfile.ZipFile(zp, "w") as z:
            z.writestr("a/m.pth", b"w")
            z.writestr("a/m.index", b"IwFl" + b"\0" * 8)
        res = rvc.import_model(str(self.tmp / "models"), "x", zip_path=str(zp), loader=loader)
        self.assertTrue(res["info"]["has_index"])


class ImportFlow(Tmp):
    def fake_loader(self, path):
        return good_checkpoint()

    def make_pth(self, name="m.pth", body=b"weights-1"):
        p = self.tmp / name
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("archive/data.pkl", body)
        return p

    def test_import_is_atomic_slugged_and_idempotent(self):
        models = self.tmp / "models"
        pth = self.make_pth()
        idx = self.tmp / "m.index"
        idx.write_bytes(b"IwFl" + b"\0" * 20)
        res = rvc.import_model(str(models), "My Voice", pth=str(pth), index=str(idx), loader=self.fake_loader,
                               source_url="https://example.com/m.pth")
        self.assertRegex(res["id"], r"^my-voice-[0-9a-f]{8}$")
        self.assertEqual(sorted(os.listdir(res["model_dir"])), ["meta.json", "my-voice.index", "my-voice.pth"])
        self.assertEqual(os.listdir(models), [res["id"]])   # no staging folder left behind
        meta = json.load(open(os.path.join(res["model_dir"], "meta.json")))
        self.assertEqual((meta["name"], meta["source_url"], meta["info"]["version"]), ("My Voice", "https://example.com/m.pth", "v2"))
        again = rvc.import_model(str(models), "My Voice", pth=str(pth), loader=self.fake_loader)
        self.assertTrue(again["already"])
        other = rvc.import_model(str(models), "My Voice", pth=str(self.make_pth("n.pth", b"weights-2")), loader=self.fake_loader)
        self.assertNotEqual(other["id"], res["id"])

    def test_same_model_imported_twice_concurrently_is_safe(self):
        import threading
        models = self.tmp / "models"
        pth = self.make_pth()
        results, errors = [], []

        def go():
            try:
                results.append(rvc.import_model(str(models), "Same", pth=str(pth), loader=self.fake_loader))
            except Exception as e:   # noqa: BLE001
                errors.append(e)

        threads = [threading.Thread(target=go) for _ in range(6)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(errors, [])
        self.assertEqual(len({r["model_dir"] for r in results}), 1)
        self.assertEqual(sum(1 for r in results if not r["already"]), 1)
        self.assertEqual(len(os.listdir(models)), 1)   # no stage folders left
        self.assertTrue(os.path.isfile(os.path.join(results[0]["model_dir"], "meta.json")))

    def test_infer_verifies_the_recorded_sha256_and_caches_it(self):
        models = self.tmp / "models"
        res = rvc.import_model(str(models), "V", pth=str(self.make_pth()), loader=self.fake_loader)
        folder = res["model_dir"]
        rvc.resolve_model(folder, str(models), verify=True)
        self.assertTrue(os.path.isfile(os.path.join(folder, ".verified")))
        with mock.patch.object(rvc, "file_sha256", side_effect=AssertionError("cached by mtime+size")):
            rvc.resolve_model(folder, str(models), verify=True)
        pth = os.path.join(folder, "v.pth")
        with open(pth, "ab") as f:   # swapped after the import
            f.write(b"tamper")
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.resolve_model(folder, str(models), verify=True)
        self.assertIn("changed after it was imported", str(cm.exception))
        os.remove(os.path.join(folder, "meta.json"))
        with self.assertRaises(rvc.RvcError):
            rvc.resolve_model(folder, str(models), verify=True)

    def test_failed_import_leaves_nothing(self):
        models = self.tmp / "models"

        def refuse(path):
            raise rvc.RvcError(rvc.UNSAFE_MODEL)

        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(models), "x", pth=str(self.make_pth()), loader=refuse)
        self.assertEqual(os.listdir(models), [])
        (self.tmp / "notes.txt").write_text("hi")
        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(models), "x", pth=str(self.tmp / "notes.txt"))
        with self.assertRaises(rvc.RvcError):
            rvc.import_model(str(models), "x")

    def test_zip_import_blocks_traversal_and_size(self):
        dest = self.tmp / "dest"
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.extract_model_zip(str(FIX / "traversal.zip"), str(dest))
        self.assertIn("unsafe", str(cm.exception))
        self.assertFalse((self.tmp / "evil.pth").exists())
        self.assertFalse(any(dest.glob("**/*.pth")) if dest.exists() else False)

        def build(name, entries, **kw):
            p = self.tmp / name
            with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
                for n, data in entries.items():
                    z.writestr(n, data)
            return str(p)

        for bad in ("/abs.pth", "a\\b.pth", "sub/../../x.pth", "C:evil.pth"):
            with self.assertRaises(rvc.RvcError, msg=bad):
                rvc.extract_model_zip(build("b.zip", {bad: b"x", "ok.pth": b"x"}), str(self.tmp / "d1"))
        # a traversal name hidden among ignored files still rejects the whole archive
        with self.assertRaises(rvc.RvcError):
            rvc.extract_model_zip(build("h.zip", {"ok.pth": b"x", "../readme.txt": b"x"}), str(self.tmp / "d2"))
        # too many model files; other files (and __MACOSX / dotfiles) do not count towards that cap...
        many = {"f%d.index" % i: b"x" for i in range(20)}
        many["m.pth"] = b"x"
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.extract_model_zip(build("many.zip", many), str(self.tmp / "d3"))
        self.assertIn("too many", str(cm.exception))
        noise = {"readme%d.txt" % i: b"x" for i in range(60)}
        noise.update({"__MACOSX/._m%d.pth" % i: b"j" for i in range(30)})
        noise["m.pth"] = b"x"
        rvc.extract_model_zip(build("noise.zip", noise), str(self.tmp / "d3b"))
        # ...but the whole archive is capped
        flood = {"n%d.txt" % i: b"x" for i in range(201)}
        flood["m.pth"] = b"x"
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.extract_model_zip(build("flood.zip", flood), str(self.tmp / "d3c"))
        self.assertIn("too many", str(cm.exception))
        # size: the declared size and the bytes really read both count
        big = build("big.zip", {"m.pth": b"\0" * 5000})
        with self.assertRaises(rvc.RvcError):
            rvc.extract_model_zip(big, str(self.tmp / "d4"), max_total=4000)
        # no model / several models
        with self.assertRaises(rvc.RvcError):
            rvc.extract_model_zip(build("none.zip", {"a.index": b"x"}), str(self.tmp / "d5"))
        with self.assertRaises(rvc.RvcError):
            rvc.extract_model_zip(build("two.zip", {"a.pth": b"x", "b.pth": b"y"}), str(self.tmp / "d6"))
        # a good one: nested folder, other files ignored, files land flat under fixed names
        good = build("good.zip", {"voice/v.pth": b"PTH", "voice/v.index": b"IDX", "voice/readme.txt": b"hi",
                                  "__MACOSX/voice/._v.pth": b"junk"})
        pth, index = rvc.extract_model_zip(good, str(self.tmp / "d7"))
        self.assertEqual((open(pth, "rb").read(), open(index, "rb").read()), (b"PTH", b"IDX"))
        self.assertEqual(sorted(os.listdir(self.tmp / "d7")), ["unpacked.index", "unpacked.pth"])

    def test_zip_symlink_member_is_refused(self):
        p = self.tmp / "link.zip"
        with zipfile.ZipFile(p, "w") as z:
            info = zipfile.ZipInfo("m.pth")
            info.external_attr = (0o120777 << 16)
            z.writestr(info, "/etc/passwd")
        with self.assertRaises(rvc.RvcError):
            rvc.extract_model_zip(str(p), str(self.tmp / "d"))


class Fetch(Tmp):
    class Resp:
        def __init__(self, body, length=None):
            self.body, self.pos, self.status = body, 0, 200
            self.headers = {"Content-Length": str(len(body) if length is None else length)}

        def read(self, n):
            chunk = self.body[self.pos:self.pos + n]
            self.pos += len(chunk)
            return chunk

        def getcode(self):
            return 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def test_fetch_rejects_http_and_huge(self):
        calls = []

        def opener(req):
            calls.append(req.full_url)
            return self.Resp(b"x" * 5000)

        for url in ("http://example.com/m.pth", "ftp://example.com/m.pth", "file:///etc/passwd", "//example.com/m.pth",
                    "https:///m.pth", None, "javascript:alert(1)", "http://127.0.0.1:8000/m.pth"):
            with self.assertRaises(rvc.RvcError, msg=str(url)):
                rvc.fetch_model(url, str(self.tmp), opener=opener)
        with self.assertRaises(rvc.RvcError):
            rvc.fetch_model("https://example.com/readme.html", str(self.tmp), opener=opener)
        self.assertEqual(calls, [])   # nothing was requested for any of them
        with self.assertRaises(rvc.RvcError) as cm:
            rvc.fetch_model("https://example.com/m.pth", str(self.tmp), opener=opener, max_bytes=1000)
        self.assertIn("larger than expected", str(cm.exception))
        self.assertEqual(os.listdir(self.tmp / "fetch"), [])   # the oversize .part is deleted
        path, kind = rvc.fetch_model("https://example.com/m.pth", str(self.tmp), opener=opener)
        self.assertEqual((kind, os.path.getsize(path)), ("pth", 5000))
        self.assertEqual(calls, ["https://example.com/m.pth"] * 2)

    def test_redirect_to_http_is_refused_by_the_downloader(self):
        handler = cns_engines._HttpsOnlyRedirect()
        with self.assertRaises(cns_engines.EngineError):
            handler.redirect_request(mock.Mock(), None, 302, "Found", {}, "http://example.com/m.pth")

    def test_huggingface_blob_links_become_resolve_links(self):
        self.assertEqual(rvc.normalize_model_url("https://huggingface.co/YukiKaze1337/DaFeiYu_rvc_v2_40k/blob/ee6b15f7/DaFeiYu.pth"),
                         "https://huggingface.co/YukiKaze1337/DaFeiYu_rvc_v2_40k/resolve/ee6b15f7/DaFeiYu.pth")
        self.assertEqual(rvc.normalize_model_url("https://example.com/blob/x/m.pth"), "https://example.com/blob/x/m.pth")
        self.assertEqual(rvc.normalize_model_url(" https://huggingface.co/a/b/resolve/main/m.zip?download=true#frag "),
                         "https://huggingface.co/a/b/resolve/main/m.zip?download=true")

    def test_offline_mode_blocks_every_download_unless_explicit(self):
        calls = []

        def opener(req):
            calls.append(req.full_url)
            return self.Resp(b"PK")

        with mock.patch.dict(os.environ, {"OV_OFFLINE": "1"}):
            with self.assertRaises(rvc.cns_net.OfflineError) as cm:
                rvc.fetch_model("https://example.com/m.zip", str(self.tmp), opener=opener)
            self.assertIn("Offline mode is on", str(cm.exception))
            self.assertIn("Settings", str(cm.exception))
            self.assertEqual(calls, [])
            path, kind = rvc.fetch_model("https://example.com/m.zip", str(self.tmp), opener=opener, explicit_download=True)
        self.assertEqual((kind, len(calls)), ("zip", 1))
        with mock.patch.dict(os.environ, {"OV_OFFLINE": "0"}):
            self.assertEqual(rvc.fetch_model("https://example.com/m2.zip", str(self.tmp), opener=opener)[1], "zip")


class FetchCommand(Tmp):
    def test_fetch_command_only_downloads_and_returns_the_path(self):
        events = []
        body = b"PK-model"

        def fake(url, work, emit_fn=None, **kw):
            p = os.path.join(work, "fetch", "m.pth")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "wb").write(body)
            return p, "pth"

        models = self.tmp / "models"
        with mock.patch.object(rvc, "fetch_model", fake), mock.patch.object(rvc.cns_proto, "emit", lambda ev, **kw: events.append((ev, kw))), \
                mock.patch.object(rvc, "import_model", side_effect=AssertionError("fetch must not import")):
            rvc.cmd_fetch({"url": "https://example.com/a/Cool.pth", "work_dir": str(self.tmp), "models_dir": str(models)})
        res = [kw for ev, kw in events if ev == "result"][0]["data"]
        self.assertEqual((res["kind"], res["name"], res["size_bytes"]), ("pth", "Cool", len(body)))
        self.assertTrue(os.path.isfile(res["path"]))
        self.assertFalse(models.exists())


class Batch(Tmp):
    def test_batch_collects_failures_and_continues(self):
        events = []

        def one(path, n):
            if "bad" in path:
                raise rvc.RvcError("The recording is silent — nothing to convert")
            if "boom" in path:
                raise ValueError("kaput")
            return "/out/%d.wav" % n

        files = ["/a/ok1.wav", "/a/bad.wav", "/a/boom.wav", "/a/ok2.wav"]
        outputs, failed = rvc.run_batch(files, one, lambda ev, **kw: events.append((ev, kw)))
        self.assertEqual(outputs, ["/out/0.wav", "/out/3.wav"])
        self.assertEqual([f["input"] for f in failed], ["/a/bad.wav", "/a/boom.wav"])
        self.assertEqual(failed[0]["error"], "The recording is silent — nothing to convert")
        self.assertIn("ValueError", failed[1]["error"])
        self.assertEqual([kw["value"] for ev, kw in events], [0.25, 0.5, 0.75, 1.0])

    def test_batch_request_limits(self):
        req = {"inputs": ["x.wav"] * 201, "model": "m", "outputs_dir": str(self.tmp)}
        with mock.patch.object(rvc, "_convert_files", side_effect=AssertionError("must not load the engine")):
            with self.assertRaises(rvc.RvcError):
                rvc.cmd_batch(req)
            with self.assertRaises(rvc.RvcError):
                rvc.cmd_batch({"inputs": [], "model": "m"})
            with self.assertRaises(rvc.RvcError):
                rvc.cmd_batch({"inputs": ["a.wav"], "pitch": 99})


class Protocol(Tmp):
    def run_cli(self, command, req):
        r = subprocess.run([sys.executable, str(HERE.parent / "Sources" / "cns_rvc.py"), command], input=json.dumps(req),
                           capture_output=True, text=True, timeout=60, cwd=str(self.tmp),
                           env=dict(os.environ, CNS_ALLOWED_ROOTS=str(self.tmp)))
        events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        return r.returncode, events

    def test_errors_are_events_with_action_text(self):
        code, ev = self.run_cli("infer", {"pitch": 99, "input": "x.wav"})
        self.assertEqual(code, 1)
        self.assertEqual(ev[-1]["event"], "error")
        self.assertIn("Pitch must be between", ev[-1]["msg"])
        code, ev = self.run_cli("infer", {"input": "x.wav", "model": "m", "outputs_dir": str(self.tmp), "work_dir": str(self.tmp)})
        self.assertEqual(ev[-1]["event"], "error")
        self.assertIn("not installed", ev[-1]["msg"])   # no Applio in the working directory
        code, ev = self.run_cli("explode", {})
        self.assertEqual(code, 2)

    def test_import_command_refuses_a_bad_file_without_torch(self):
        code, ev = self.run_cli("import", {"pth": str(FIX / "not-a-pickle.pth"), "name": "x", "models_dir": str(self.tmp / "m")})
        self.assertEqual(code, 1)
        self.assertEqual(ev[-1]["msg"], "This isn’t a safe voice model file")
        self.assertEqual(os.listdir(self.tmp / "m"), [])


class SeedVC(Tmp):
    def test_seedvc_args_match_1_0_3(self):
        import worker
        captured = {}

        def fake_run(cmd, **kw):
            captured["cmd"], captured["kw"] = list(cmd), kw
            return subprocess.CompletedProcess(cmd, 1, "", "")

        tgt = self.tmp / "t.wav"
        make_wav(tgt, 1.0, rate=24000)
        spec = {"dir": str(self.tmp), "python": "/py/python"}
        (self.tmp / "seed-vc").mkdir()
        import numpy as np
        with mock.patch("subprocess.run", fake_run), mock.patch.object(worker, "write_wav", lambda p, a: None), \
                mock.patch.object(worker, "load_mono", lambda p: np.zeros(48000, dtype=np.float32)):
            with self.assertRaises(Exception):
                worker.convert_voice(spec, np.zeros(100, dtype=np.float32), str(tgt))
        old = captured["cmd"]
        ours = seedvc.build_args("S", "T", "O")
        self.assertEqual(old[0], "/py/python")
        self.assertEqual(old[1:2], ours[:1])
        flags_old = {old[i]: old[i + 1] for i in range(2, len(old), 2)}
        flags_new = {ours[i]: ours[i + 1] for i in range(1, len(ours), 2)}
        for key in ("--diffusion-steps", "--length-adjust", "--inference-cfg-rate", "--fp16"):
            self.assertEqual(flags_old[key], flags_new[key], key)
        self.assertEqual(set(flags_old), set(flags_new))
        self.assertEqual(captured["kw"]["env"]["PYTORCH_ENABLE_MPS_FALLBACK"], "1")
        self.assertEqual(seedvc.child_env(str(self.tmp), str(self.tmp))["PYTORCH_ENABLE_MPS_FALLBACK"], "1")
        self.assertEqual(seedvc.TARGET_SECONDS, 25)

    def test_seedvc_validation_and_only_pinned_modes(self):
        self.assertEqual(seedvc.validate_request({}), {"steps": 50, "cfg_rate": 0.7, "length_adjust": 1.0})
        for bad in ({"steps": 9}, {"steps": 101}, {"steps": 10.5}, {"cfg_rate": 2}, {"length_adjust": 0.1}, {"length_adjust": "x"}):
            with self.assertRaises(rvc.RvcError, msg=str(bad)):
                seedvc.validate_request(bad)
        for unpinned in ({"f0_condition": True}, {"checkpoint": "/x.pth"}, {"config": "/x.yml"}, {"fp16": True}):
            with self.assertRaises(rvc.RvcError):
                seedvc.validate_request(unpinned)
        args = seedvc.build_args("s", "t", "o", steps=100, cfg_rate=0.5, length_adjust=1.2)
        self.assertNotIn("--f0-condition", args)
        self.assertNotIn("--checkpoint", args)
        self.assertEqual(args[args.index("--diffusion-steps") + 1], "100")
        # the default (v2) model files named in the pins are all that inference.py loads without those flags
        self.assertTrue(any("DiT_seed_v2_uvit_whisper_small_wavenet" in e["path"]
                            for m in cns_engines.pins.SEEDVC_MODELS for e in m["files"]))

    def test_seedvc_runs_sandboxed_without_network(self):
        cmd = seedvc.sandboxed_command(str(self.tmp), ["/py/python", "inference.py"], str(self.tmp))
        self.assertEqual(cmd[:2], ["/usr/bin/sandbox-exec", "-f"])
        self.assertTrue(cmd[2].endswith("engine.sb"))   # the shared profile, not an own one
        self.assertIn("NET=deny-ip", cmd)
        self.assertEqual(cmd[-2:], ["/py/python", "inference.py"])
        env = seedvc.child_env(str(self.tmp), str(self.tmp))
        self.assertEqual(env["HF_HUB_OFFLINE"], "1")
        self.assertNotIn("HF_TOKEN", env)

    def test_seedvc_wraps_itself_unless_the_app_sandboxed_it(self):
        base = ["/py/python", "inference.py"]
        wrapped = seedvc.wrap_command(str(self.tmp), base, str(self.tmp), env={})
        self.assertEqual(wrapped[0], "/usr/bin/sandbox-exec")
        # strays are not trusted: the real marker file is needed (cns_engines.already_sandboxed)
        for env in ({"CNS_SANDBOXED": "1"}, {"CNS_SANDBOX_FILE": "/x/p.sb"}, {"CNS_SANDBOXED": "1", "CNS_SANDBOX_FILE": "/x/p.sb"}):
            self.assertEqual(seedvc.wrap_command(str(self.tmp), base, str(self.tmp), env=env)[0], "/usr/bin/sandbox-exec")
        sb = cns_engines.sandbox_file()
        self.assertEqual(seedvc.wrap_command(str(self.tmp), base, str(self.tmp),
                                             env={"CNS_SANDBOXED": "1", "CNS_SANDBOX_FILE": sb}), base)
        with mock.patch.object(cns_engines, "SANDBOX_EXEC", "/nonexistent/sandbox-exec"):   # never run unsandboxed
            with self.assertRaises(rvc.RvcError) as cm:
                seedvc.wrap_command(str(self.tmp), base, str(self.tmp), env={})
        self.assertIn("sandbox", str(cm.exception))

    def test_trim_wav_keeps_at_most_25_seconds(self):
        src = self.tmp / "long.wav"
        make_wav(src, 30.0, rate=8000)
        got = seedvc.trim_wav(str(src), str(self.tmp / "short.wav"), 25)
        self.assertAlmostEqual(got, 25.0, delta=0.01)
        short = self.tmp / "s.wav"
        make_wav(short, 2.0, rate=8000)
        self.assertAlmostEqual(seedvc.trim_wav(str(short), str(self.tmp / "s2.wav"), 25), 2.0, delta=0.01)


if __name__ == "__main__":
    unittest.main()
