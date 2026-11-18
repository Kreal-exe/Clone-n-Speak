"""Tests for Sources/cns_stems.py and cns_stems_catalog.py. No torch, no audio-separator: fakes only."""
import hashlib
import http.server
import json
import os
import pathlib
import re
import sys
import tempfile
import threading
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "Sources"))

import cns_pins as pins  # noqa: E402
import cns_proto  # noqa: E402
import cns_stems as stems  # noqa: E402
import cns_stems_catalog as cat  # noqa: E402

try:
    import numpy as np
except ImportError:  # the system 3.9 has none; those tests are skipped there
    np = None

NOTES = ROOT / "docs" / "superpowers" / "notes" / "2026-11-09-stem-licenses.md"
UNVERIFIED_ACCEPTED = {"kim-vocal-2", "bs-roformer"}   # the user's decision of 2026-11-18


def touch(path, data=b"\0" * 4000):
    with open(path, "wb") as f:
        f.write(data)
    return path


class Catalog(unittest.TestCase):
    def test_catalog_only_verified_entries(self):
        self.assertTrue(cat.CATALOG)
        notes = NOTES.read_text()
        seen_unverified = set()
        for e in cat.CATALOG:
            self.assertTrue(e["license_url"].startswith("https://"), e["id"])
            self.assertTrue(e["license_evidence"], e["id"])
            self.assertIn("`%s`" % e["id"], notes, "no row in the license notes for %s" % e["id"])
            if e["verified"]:
                self.assertIn(e["license"], cat.OPEN_LICENSES, e["id"])
            else:
                # only the two models the user accepted may be unverified, and they say so
                seen_unverified.add(e["id"])
                self.assertEqual(e["license"], cat.UNVERIFIED)
                self.assertTrue(e["accepted_by_user"], e["id"])
                self.assertIn("unverified", e["note"].lower())
        self.assertEqual(seen_unverified, UNVERIFIED_ACCEPTED)

    def test_unlicensed_models_are_not_offered(self):
        for e in cat.ALL:
            if not e["verified"] and not e["accepted_by_user"]:
                self.assertNotIn(e, cat.CATALOG)
        self.assertNotIn("nsosu", json.dumps(cat.CATALOG).lower())   # UMX-L, CC BY-NC-SA: not offered

    def test_catalog_entries_have_sha256_and_https_url(self):
        for e in cat.CATALOG:
            self.assertRegex(e["sha256"], r"^[0-9a-f]{64}$", e["id"])
            self.assertTrue(e["url"].startswith("https://"), e["id"])
            self.assertGreater(e["size"], 0, e["id"])
            self.assertIn(e["kind"], cat.KINDS)
            self.assertIn(e["arch"], cat.ARCHS)
            self.assertIn(e["file"], e["files"])
            self.assertIn(e["load_file"], e["files"])
            for meta in ("download_checks.json", "mdx_model_data.json", "vr_model_data.json"):
                self.assertIn(meta, e["files"], "the separator would fetch %s itself" % meta)
            for spec in pins.STEMS[e["id"]]:
                self.assertRegex(spec["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(spec["url"].startswith("https://"))

    def test_defaults_and_sizes_match_the_spike(self):
        self.assertEqual(cat.get(cat.DEFAULT_ID)["file"], "Kim_Vocal_2.onnx")
        self.assertEqual(cat.get(cat.DEFAULT_ID)["size"], 66759214)
        self.assertEqual(cat.get(cat.QUALITY_ID)["file"], "model_bs_roformer_ep_317_sdr_12.9755.ckpt")
        self.assertEqual(cat.get(cat.DEFAULT_ID)["peak_gb"], 6.5)
        self.assertEqual(cat.get(cat.QUALITY_ID)["peak_gb"], 6.6)

    def test_every_pinned_stem_model_has_a_catalog_entry(self):
        self.assertEqual(set(pins.STEMS), {e["id"] for e in cat.ALL})


class Request(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.wav = touch(os.path.join(self.tmp.name, "in.wav"))

    def test_separate_request_validation(self):
        ok = stems.validate_request({"input": self.wav, "model": "kim-vocal-2", "stems": "vocals",
                                     "output_format": "FLAC"})
        self.assertEqual((ok["format"], ok["stems"]), ("flac", ["vocals"]))
        for bad, msg in [
            ({"input": self.wav, "model": "no-such"}, "Unknown separation model"),
            ({"input": self.wav, "model": "kim-vocal-2", "output_format": "ogg"}, "Unsupported output format"),
            ({"input": self.wav, "model": "kim-vocal-2", "stems": "drums"}, "cannot give"),
            ({"input": os.path.join(self.tmp.name, "missing.wav"), "model": "kim-vocal-2"}, "not found"),
            ({"model": "kim-vocal-2"}, "No input"),
            ({"input": self.wav, "chunk_s": 3}, "chunk_s"),
        ]:
            with self.assertRaises(cns_proto.ProtoError) as cm:
                stems.validate_request(bad)
            self.assertIn(msg, str(cm.exception))

    def test_output_outside_roots_refused(self):
        with self.assertRaises(cns_proto.ProtoError):
            stems.validate_request({"input": self.wav, "outputs_dir": "/etc"}, roots=[self.tmp.name])

    def test_instrumental_is_derived_for_demucs_only(self):
        self.assertEqual(stems.wanted_stems(cat.get("htdemucs"), "instrumental"), ["instrumental"])
        self.assertEqual(stems.wanted_stems(cat.get("htdemucs"), "all"),
                         ["vocals", "drums", "bass", "other", "instrumental"])
        self.assertEqual(stems.wanted_stems(cat.get("kim-vocal-2"), "all"), ["vocals", "instrumental"])

    def test_stem_names_map(self):
        for name, want in [("song_(Vocals)_Kim_Vocal_2.wav", "vocals"), ("a b_(Instrumental)_x.flac", "instrumental"),
                           ("t_(Drums)_htdemucs.wav", "drums"), ("t_(Bass)_htdemucs.wav", "bass"),
                           ("t_(Other)_htdemucs.wav", "other"), ("/w/t_(No Reverb)_dereverb.wav", "dry"),
                           ("t_(Reverb)_dereverb.wav", "reverb"), ("t_(Mystery)_m.wav", None), ("plain.wav", None),
                           ("my_(Vocals)_cut_(Instrumental)_m.wav", "instrumental")]:
            self.assertEqual(stems.stem_name(name), want, name)

    def test_short_and_silent_input_errors(self):
        for frames, sr, peak, msg in [(100, 44100, 0.5, "shorter than 1 second"), (22000, 44100, 0.5, "shorter"),
                                      (44100 * 5, 44100, 0.0, "silent"), (44100 * 5, 44100, 5e-5, "silent"),
                                      (0, 44100, 0.0, "no audio")]:
            with self.assertRaises(stems.StemError) as cm:
                stems.check_audio(frames, sr, peak)
            self.assertIn(msg, str(cm.exception))
        stems.check_audio(44100, 44100, 0.1)   # exactly one second passes

    def test_long_input_is_chunked(self):
        sr = 44100
        short = stems.plan_chunks(60 * sr, sr)
        self.assertEqual(short, [(0, 60 * sr)])
        for minutes in (10, 60, 180):
            total = minutes * 60 * sr
            plan = stems.plan_chunks(total, sr)
            self.assertEqual((plan[0][0], plan[-1][1]), (0, total))
            self.assertGreater(len(plan), 1)
            # peak memory follows the biggest chunk, which does not grow with the file
            self.assertEqual(max(b - a for a, b in plan), stems.CHUNK_DEFAULT_S * sr)
            for (a1, b1), (a2, b2) in zip(plan, plan[1:]):
                self.assertEqual(b1 - a2, int(stems.OVERLAP_S * sr))   # neighbours overlap, nothing is skipped


class FakeSeparator:
    """Stands in for audio-separator: splits a mix into two stems and records how it was called."""
    created = []

    def __init__(self, model_dir, work, fmt, io, names=("Vocals", "Instrumental")):
        self.model_dir, self.work, self.fmt, self.io, self.names = model_dir, work, fmt, io, names
        self.loaded = None
        self.downloaded = []
        self.dir_listing = sorted(os.listdir(model_dir))
        FakeSeparator.created.append(self)

    def load_model(self, model_filename=None):
        self.loaded = model_filename

    def separate(self, path):
        data, sr = self.io.read(path)
        base = os.path.splitext(os.path.basename(path))[0]
        out = []
        for i, n in enumerate(self.names):
            p = os.path.join(self.work, "%s_(%s)_fake.wav" % (base, n))
            self.io.write(p, data * (0.5 if i == 0 else 0.25), sr)
            out.append(os.path.basename(p))
        return out


class _Files(dict):
    """Keys are real paths, so /var and /private/var spellings meet."""

    def __getitem__(self, k):
        return dict.__getitem__(self, os.path.realpath(k))

    def __setitem__(self, k, v):
        dict.__setitem__(self, os.path.realpath(k), v)

    def pop(self, k, *a):
        return dict.pop(self, os.path.realpath(k), *a)


def _touch(path):
    if os.path.isdir(os.path.dirname(path)):
        pathlib.Path(path).touch()


class MemIO:
    """Audio in a dict instead of files: path -> (float32 array, samplerate)."""

    def __init__(self):
        self.np = np
        self.files = _Files()
        self.writers = []

    def info(self, path):
        d, sr = self.files[path]
        return len(d), sr, d.shape[1]

    def peak(self, path):
        return float(abs(self.files[path][0]).max())

    def read(self, path, start=0, frames=-1):
        d, sr = self.files[path]
        return (d[start:] if frames < 0 else d[start:start + frames]).copy(), sr

    def write(self, path, data, samplerate):
        self.files[path] = (np.array(data, dtype="float32"), samplerate)
        _touch(path)

    def move(self, src, dest):
        self.files[dest] = self.files.pop(src)
        os.replace(src, dest)

    def writer(self, path, samplerate, channels, fmt):
        io = self

        class W:
            def __init__(self):
                self.parts = []

            def write(self, block):
                self.parts.append(np.array(block, dtype="float32"))

            def close(self):
                io.files[path] = (np.concatenate(self.parts) if self.parts else np.zeros((0, channels), "float32"),
                                  samplerate)
                _touch(path)
        w = W()
        self.writers.append(w)
        return w


class Events:
    def __init__(self):
        self.log = []

    def status(self, msg):
        self.log.append(("status", msg))

    def progress(self, v):
        self.log.append(("progress", v))


@unittest.skipIf(np is None, "numpy not available in this interpreter")
class Separate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.engines = os.path.join(t, "engines")
        self.work = os.path.join(t, "work")
        self.out = os.path.join(t, "out")
        os.makedirs(self.work)
        os.makedirs(self.out)
        self.io = MemIO()
        FakeSeparator.created = []
        self.input = os.path.join(t, "mix.wav")
        touch(self.input)

    def install(self, model_id):
        folder = cat.model_dir(self.engines, model_id)
        os.makedirs(folder)
        for spec in pins.STEMS[model_id]:
            touch(os.path.join(folder, spec["path"]), b"x" * spec["size"] if spec["size"] < 10000 else b"")
            with open(os.path.join(folder, spec["path"]), "r+b") as f:
                f.truncate(spec["size"])   # sparse: the right size, no real bytes

    def audio(self, seconds, sr=44100, amp=0.4):
        n = int(seconds * sr)
        wave = (amp * np.sin(np.arange(n) * 0.05)).astype("float32")
        self.io.files[self.input] = (np.stack([wave, wave], 1), sr)
        return wave

    def go(self, req=None, **kw):
        r = {"input": self.input, "model": "kim-vocal-2", "stems": "all", "work_dir": self.work,
             "outputs_dir": self.out}
        r.update(req or {})
        factory = lambda d, w, f: FakeSeparator(d, w, f, self.io, **kw)  # noqa: E731
        return stems.separate(r, emit=Events(), root=self.engines, io=self.io, separator_factory=factory)

    def test_models_downloaded_by_url_not_by_separator(self):
        self.audio(5)
        with self.assertRaises(stems.StemError) as cm:   # not installed: no download is attempted
            self.go()
        self.assertIn("not installed", str(cm.exception))
        self.assertEqual(FakeSeparator.created, [])
        self.install("kim-vocal-2")
        res = self.go()
        sep = FakeSeparator.created[0]
        self.assertEqual(sep.model_dir, cat.model_dir(self.engines, "kim-vocal-2"))
        self.assertEqual(sep.loaded, "Kim_Vocal_2.onnx")
        self.assertIn("Kim_Vocal_2.onnx", sep.dir_listing)   # the file was already there when the separator started
        self.assertEqual(res["model"], "kim-vocal-2")
        self.install("htdemucs")
        self.go({"model": "htdemucs", "stems": "vocals"}, names=("Vocals", "Drums", "Bass", "Other"))
        self.assertEqual(FakeSeparator.created[-1].loaded, "htdemucs.yaml")   # Demucs is loaded by its config name

    def test_wrong_size_file_counts_as_not_installed(self):
        self.audio(5)
        self.install("kim-vocal-2")
        p = os.path.join(cat.model_dir(self.engines, "kim-vocal-2"), "Kim_Vocal_2.onnx")
        os.truncate(p, 100)
        with self.assertRaises(stems.StemError):
            self.go()

    def test_one_chunk_gives_a_file_per_stem(self):
        self.audio(5)
        self.install("kim-vocal-2")
        res = self.go()
        names = sorted(os.path.basename(p) for p in res["outputs"])
        self.assertEqual(names, ["mix_instrumental.wav", "mix_vocals.wav"])
        for p in res["outputs"]:
            self.assertTrue(p.startswith(self.out))
        self.assertEqual(self.io.files[res["outputs"][0]][0].shape, (5 * 44100, 2))
        self.assertEqual(os.listdir(self.work), [])   # chunk and stem scratch files are gone

    def test_only_the_requested_stem_is_written(self):
        self.audio(5)
        self.install("kim-vocal-2")
        res = self.go({"stems": "vocals"})
        self.assertEqual([os.path.basename(p) for p in res["outputs"]], ["mix_vocals.wav"])

    def test_chunked_run_stitches_without_gaps_or_steps(self):
        wave = self.audio(40)
        self.install("kim-vocal-2")
        res = self.go({"chunk_s": 10, "stems": "vocals"})
        self.assertGreater(res["chunks"], 3)
        stem = self.io.files[res["outputs"][0]][0][:, 0]
        self.assertEqual(len(stem), len(wave))           # same length as the input
        self.assertLess(float(abs(stem - wave * 0.5).max()), 1e-5)   # the fake scales by 0.5; cross-fade keeps it exact

    def test_demucs_instrumental_is_the_sum_of_the_rest(self):
        wave = self.audio(12)
        self.install("htdemucs")
        res = self.go({"model": "htdemucs", "stems": "instrumental", "chunk_s": 10},
                       names=("Vocals", "Drums", "Bass", "Other"))
        stem = self.io.files[res["outputs"][0]][0][:, 0]
        # fake gives vocals 0.5, others 0.25 each: instrumental = 3 * 0.25
        self.assertLess(float(abs(stem - wave * 0.75).max()), 1e-5)
        self.assertEqual(len(res["outputs"]), 1)

    def test_progress_and_unreadable_model_output(self):
        self.audio(25)
        self.install("kim-vocal-2")
        ev = Events()
        r = {"input": self.input, "model": "kim-vocal-2", "stems": "all", "work_dir": self.work,
             "outputs_dir": self.out, "chunk_s": 10}
        stems.separate(r, emit=ev, root=self.engines, io=self.io,
                       separator_factory=lambda d, w, f: FakeSeparator(d, w, f, self.io))
        values = [v for k, v in ev.log if k == "progress"]
        self.assertEqual(values, sorted(values))
        self.assertAlmostEqual(values[-1], 1.0)
        with self.assertRaises(stems.StemError):   # a model that names no known stem
            self.go(names=("Mystery",))

    def test_silent_input_fails_before_the_model_loads(self):
        self.audio(5, amp=0.0)
        self.install("kim-vocal-2")
        with self.assertRaises(stems.StemError):
            self.go()
        self.assertEqual(FakeSeparator.created, [])


@unittest.skipIf(np is None, "numpy not available in this interpreter")
class StitcherMath(unittest.TestCase):
    def test_crossfade_of_equal_signals_is_transparent(self):
        io = MemIO()
        s = stems.Stitcher(io, "/x/out.wav", "wav", overlap_s=1.0)
        sr = 100
        full = np.sin(np.arange(1000) * 0.1).astype("float32")[:, None]
        plan = stems.plan_chunks(1000, sr, chunk_s=4.0, overlap_s=1.0)
        for i, (a, b) in enumerate(plan):
            s.add(full[a:b], sr, i == 0, i == len(plan) - 1)
        s.close()
        out = io.files["/x/out.wav"][0]
        self.assertEqual(out.shape, full.shape)
        self.assertLess(float(abs(out - full).max()), 1e-6)


class FetchModel(unittest.TestCase):
    def test_fetch_model_checks_sha256_and_places_files(self):
        body = b"model-bytes" * 100
        spec = {"path": "w.bin", "url": "", "sha256": hashlib.sha256(body).hexdigest(), "size": len(body)}

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
        spec["url"] = "http://127.0.0.1:%d/w.bin" % srv.server_port
        orig = pins.STEMS["kim-vocal-2"]
        pins.STEMS["kim-vocal-2"] = [spec]
        self.addCleanup(lambda: pins.STEMS.__setitem__("kim-vocal-2", orig))
        with tempfile.TemporaryDirectory() as t, self.assertRaises(Exception) as cm:
            stems.fetch_model(t, "no-such-model")
        self.assertIn("Unknown", str(cm.exception))
        with tempfile.TemporaryDirectory() as t:
            res = stems.fetch_model(t, "kim-vocal-2")
            with open(os.path.join(res["folder"], "w.bin"), "rb") as f:
                self.assertEqual(f.read(), body)
            self.assertEqual(os.listdir(res["folder"]), ["w.bin"])   # no .part left behind


if __name__ == "__main__":
    unittest.main()
