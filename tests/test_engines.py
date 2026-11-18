"""Tests for Sources/cns_engines.py (pro-engine manager). No internet: a 127.0.0.1 server, a fake uv, tars in memory."""
import shlex
import hashlib
import http.server
import io
import json
import os
import pathlib
import socket
import stat
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Sources"))

import cns_engines as eng  # noqa: E402
import cns_pins as pins    # noqa: E402


def sha(b):
    return hashlib.sha256(b).hexdigest()


def make_tar(members):
    """members: {name: bytes | ("link", target)} -> tar.gz bytes, all under a top folder unless the name has '..'."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, content in members.items():
            if isinstance(content, tuple):
                info = tarfile.TarInfo(name)
                info.type = tarfile.SYMTYPE
                info.linkname = content[1]
                tar.addfile(info)
            else:
                info = tarfile.TarInfo(name)
                info.size = len(content)
                tar.addfile(info, io.BytesIO(content))
    return buf.getvalue()


class Server:
    """Serves FILES with Range support; CUT[path] = n makes the next response stop after n bytes (once)."""

    def __init__(self):
        self.files, self.cut, self.requests = {}, {}, []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                body = outer.files.get(self.path)
                outer.requests.append((self.path, self.headers.get("Range")))
                if body is None:
                    self.send_error(404)
                    return
                start, code = 0, 200
                rng = self.headers.get("Range")
                if rng and rng.startswith("bytes="):
                    start = int(rng[6:].split("-")[0])
                    if start >= len(body):
                        self.send_error(416)
                        return
                    code = 206
                chunk = body[start:]
                self.send_response(code)
                self.send_header("Content-Length", str(len(chunk)))
                if code == 206:
                    self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(body) - 1, len(body)))
                self.end_headers()
                cut = outer.cut.pop(self.path, None)
                if cut is not None:
                    self.wfile.write(chunk[:cut])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                self.wfile.write(chunk)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


FAKE_UV = """import os, sys, json, shlex
a = sys.argv[1:]
json.dump(dict(os.environ), open("{dump}/uv_env.json", "w"))
log = os.environ.get("FAKE_UV_LOG")
if log:
    open(log, "a").write(" ".join(a) + "\\n")
if os.environ.get("FAKE_UV_FAIL") and a[:2] == ["pip", "install"] and os.environ["FAKE_UV_FAIL"] in " ".join(a):
    print("boom")
    sys.exit(2)
if a[0] == "venv":
    d = a[-1]
    os.makedirs(os.path.join(d, "bin"), exist_ok=True)
    p = os.path.join(d, "bin", "python")
    open(p + ".py", "w").write("import sys, os\\nif sys.argv[1:2] == ['inference.py']:\\n"
                       "    out = sys.argv[sys.argv.index('--output') + 1]\\n    import json\\n    json.dump(dict(os.environ), open('{dump}/warm_env.json', 'w'))\\n    open(os.path.join(out, 'vc.wav'), 'wb').write(b'RIFF')\\n")
    open(p, "w").write("#!/bin/sh\\nexec " + shlex.quote("{py}") + " " + shlex.quote(p + ".py") + " \\"$@\\"\\n")
    os.chmod(p, 0o755)
else:
    for i in range(5):
        print("line", i)
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "engines")
        self.srv = Server()
        self.addCleanup(self.srv.close)
        self.uv = os.path.join(self.tmp.name, "uv")
        with open(self.uv + ".py", "w") as f:
            f.write(FAKE_UV.format(py=sys.executable, dump=self.tmp.name))
        with open(self.uv, "w") as f:   # a shell wrapper: a shebang cannot hold an interpreter path with spaces
            f.write("#!/bin/sh\nexec %s %s \"$@\"\n" % (shlex.quote(sys.executable), shlex.quote(self.uv + ".py")))
        os.chmod(self.uv, 0o755)
        self.events = []
        self.emit = lambda event, **kw: self.events.append((event, kw))
        # fixture pins: tiny weights and tarballs on the local server
        self.blobs = {}
        weights = {}
        for cid in ("rvc-core", "rvc-fcpe", "rvc-train-32k", "rvc-train-40k", "rvc-train-48k"):
            entries = []
            for i, name in enumerate(("a.bin", "b.bin") if cid == "rvc-core" else ("a.bin",)):
                data = (cid + name).encode() * (3000 + i)
                self.srv.files["/w/%s/%s" % (cid, name)] = data
                entries.append({"path": "%s/%s" % (cid, name), "url": self.srv.url("/w/%s/%s" % (cid, name)),
                                "sha256": sha(data), "size": len(data)})
            weights[cid] = entries
        self.applio_members = {"core.py": b"print(1)\n", "LICENSE": b"MIT\n", "rvc/__init__.py": b"",
                               "rvc/infer/infer.py": b"x = 1\n", "assets/config_template.json": b"{}",
                               "requirements-engine.txt": b"numpy\n", "logs/mute/m.npy": b"mute"}
        applio_tar = make_tar(dict(("Applio-x/" + k, v) for k, v in self.applio_members.items()
                                   ) | {"Applio-x/tabs/app.py": b"gradio", "Applio-x/rvc/models/keep": b"."})
        self.srv.files["/applio.tgz"] = applio_tar
        self.seed_members = {"inference.py": b"print('vc')\n", "LICENSE": b"GPL\n"}
        self.srv.files["/seedvc.tgz"] = make_tar(dict(("seed-x/" + k, v) for k, v in self.seed_members.items()))
        self.srv.files["/m/dit.pth"] = b"dit-weights" * 500
        self.srv.files["/m/cfg.json"] = b"{}"
        models = [
            {"repo": "org/dit", "rev": "a" * 40, "cache": "checkpoints",
             "files": [{"path": "dit.pth", "url": self.srv.url("/m/dit.pth"), "sha256": sha(self.srv.files["/m/dit.pth"]),
                        "size": len(self.srv.files["/m/dit.pth"])}]},
            {"repo": "org/voc", "rev": "b" * 40, "cache": "hub",
             "files": [{"path": "sub/config.json", "url": self.srv.url("/m/cfg.json"), "sha256": sha(b"{}"), "size": 2}]}]
        patches = dict(
            SEEDVC_MODELS=models,
            APPLIO_SIZES={k: len(v) for k, v in self.applio_members.items()},
            SEEDVC_SIZES={k: len(v) for k, v in self.seed_members.items()},
            WEIGHTS=weights, STEMS={},
            APPLIO_URL=self.srv.url("/applio.tgz"), APPLIO_FILES={k: sha(v) for k, v in self.applio_members.items()},
            SEEDVC_URL=self.srv.url("/seedvc.tgz"), SEEDVC_FILES={k: sha(v) for k, v in self.seed_members.items()})
        p = mock.patch.multiple(pins, **patches)
        p.start()
        self.addCleanup(p.stop)
        d = mock.patch.object(eng, "_check_disk")
        d.start()
        self.addCleanup(d.stop)

    def install(self, comps, **kw):
        return eng.install(self.root, comps, self.uv, kw.pop("env", {}), self.emit, **kw)

    def state(self, cid, root=None):
        rows = eng.status(root or self.root)["components"]
        return next(r["state"] for r in rows if r["id"] == cid)


class InstallTests(Base):
    def test_partial_install_is_not_ready(self):
        # a kill after applio, before rvc-core: only pro-env and applio have ready.json
        self.install(["applio"])
        st = eng.status(self.root)
        self.assertFalse(st["ready"])
        self.assertEqual(self.state("rvc-core"), "notinstalled")
        self.assertTrue(eng.is_ready(self.root, "pro-env"))
        self.assertTrue(eng.is_ready(self.root, "applio"))
        # no ready.json -> not ready, even though the python exists
        os.remove(os.path.join(self.root, "pro", "ready.json"))
        self.assertFalse(eng.is_ready(self.root, "pro-env"))
        self.assertEqual(self.state("pro-env"), "partial")
        # full install, then a truncated weight
        self.install(["rvc-core", "pro-env"])
        self.assertTrue(eng.status(self.root)["ready"])
        w = os.path.join(self.root, "weights", "rvc-core", "a.bin")
        with open(w, "r+b") as f:
            f.truncate(100)
        self.assertIn(self.state("rvc-core"), ("partial", "broken"))
        self.assertFalse(eng.status(self.root)["ready"])

    def test_install_returns_installed_in_order_and_skips_ready(self):
        self.assertEqual(self.install(["rvc-core", "applio"]), ["pro-env", "applio", "rvc-core"])
        self.assertEqual(self.install(["rvc-core", "applio"]), [])

    def test_install_resumes_download(self):
        data = self.srv.files["/w/rvc-fcpe/a.bin"]
        self.srv.cut["/w/rvc-fcpe/a.bin"] = len(data) // 2
        with self.assertRaises(eng.EngineError) as cm:
            self.install(["rvc-fcpe"])
        self.assertIn("Install again", str(cm.exception))
        part = os.path.join(self.root, "weights", "rvc-fcpe", "a.bin.part")
        self.assertTrue(os.path.exists(part))
        n = os.path.getsize(part)
        self.assertGreater(n, 0)
        self.assertLess(n, len(data))
        self.assertEqual(self.state("rvc-fcpe"), "partial")
        self.assertTrue(os.path.exists(os.path.join(self.root, "state", "rvc-fcpe", "installing.json")))
        self.srv.requests.clear()
        self.install(["rvc-fcpe"])
        self.assertIn(("/w/rvc-fcpe/a.bin", "bytes=%d-" % n), self.srv.requests)
        with open(os.path.join(self.root, "weights", "rvc-fcpe", "a.bin"), "rb") as f:
            self.assertEqual(sha(f.read()), sha(data))
        self.assertFalse(os.path.exists(part))
        self.assertTrue(eng.is_ready(self.root, "rvc-fcpe"))

    def test_server_ignoring_range_restarts_cleanly(self):
        data = self.srv.files["/w/rvc-fcpe/a.bin"]
        dest = os.path.join(self.tmp.name, "f.bin")
        with open(dest + ".part", "wb") as f:
            f.write(b"garbage-prefix")
        # a server that answers 200 with the whole body to a Range request
        real = eng._default_opener

        def opener(req):
            req.headers.pop("Range", None)
            return real(req)
        eng.download(self.srv.url("/w/rvc-fcpe/a.bin"), dest, sha(data), len(data), None, opener)
        with open(dest, "rb") as f:
            self.assertEqual(f.read(), data)

    def test_hash_mismatch_discards_part_and_fails(self):
        e = pins.WEIGHTS["rvc-fcpe"][0]
        bad = dict(e, sha256="0" * 64)
        with mock.patch.dict(pins.WEIGHTS, {"rvc-fcpe": [bad]}):
            with self.assertRaises(eng.EngineError) as cm:
                self.install(["rvc-fcpe"])
        self.assertIn("checksum", str(cm.exception))
        d = os.path.join(self.root, "weights", "rvc-fcpe")
        self.assertEqual([n for n in os.listdir(d)], [])
        self.assertNotEqual(self.state("rvc-fcpe"), "ready")

    def test_oversized_download_is_stopped(self):
        e = pins.WEIGHTS["rvc-fcpe"][0]
        small = dict(e, size=100, sha256="0" * 64)
        dest = os.path.join(self.tmp.name, "x.bin")
        with self.assertRaises(eng.EngineError):
            eng.download(small["url"], dest, small["sha256"], 100, None)
        self.assertFalse(os.path.exists(dest + ".part"))

    def test_offline_mode_blocks_installs_unless_explicit(self):
        import cns_net
        with mock.patch.dict(os.environ, {"OV_OFFLINE": "1"}):
            with self.assertRaises(cns_net.OfflineError) as cm:
                self.install(["rvc-fcpe"])
            self.assertIn("Offline mode", str(cm.exception))
            with self.assertRaises(cns_net.OfflineError):
                eng.download("https://example.invalid/x", os.path.join(tempfile.gettempdir(), "never"), None, None)
            # explicit_download (a button the user pressed) lets it through to the real work: it fails later, not here
            e = dict(pins.WEIGHTS["rvc-fcpe"][0], url="http://127.0.0.1:9/x")
            with mock.patch.dict(pins.WEIGHTS, {"rvc-fcpe": [e]}):
                with self.assertRaises(eng.EngineError):
                    eng.install(self.root, ["rvc-fcpe"], "uv", None, lambda *a, **k: None, explicit_download=True)

    def test_no_network_fails_with_action_text(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()   # nobody listens here now
        e = dict(pins.WEIGHTS["rvc-fcpe"][0], url="http://127.0.0.1:%d/x" % port)
        with mock.patch.dict(pins.WEIGHTS, {"rvc-fcpe": [e]}):
            with self.assertRaises(eng.EngineError) as cm:
                self.install(["rvc-fcpe"])
        self.assertIn("Install again", str(cm.exception))
        self.assertIn("No connection", str(cm.exception))

    def test_non_https_remote_url_refused(self):
        with self.assertRaises(eng.EngineError):
            eng.download("http://example.com/x", os.path.join(self.tmp.name, "x"), "0" * 64, 1, None)

    def test_ready_json_written_last_and_removed_first(self):
        log = []
        real = {n: getattr(eng, n) for n in ("_clear_ready", "_mark_installing", "_write_ready")}

        def wrap(name):
            def f(root, comp, *a):
                log.append((name, comp["id"]))
                if name == "_write_ready":   # everything the component needs is on disk before ready.json
                    if comp["kind"] == "weights":
                        for p, e in eng.weight_files(root, comp):
                            self.assertEqual(os.path.getsize(p), e["size"])
                    self.assertFalse(os.path.exists(eng.marker_path(root, comp)))
                return real[name](root, comp, *a)
            return f
        with mock.patch.multiple(eng, **{n: wrap(n) for n in real}):
            self.install(["rvc-core", "pro-env"])
        for cid in ("pro-env", "rvc-core"):
            seq = [n for n, c in log if c == cid]
            self.assertEqual(seq, ["_clear_ready", "_mark_installing", "_write_ready"])
        self.assertEqual([c for n, c in log if n == "_write_ready"], ["pro-env", "rvc-core"])
        comp = eng._by_id("shared")["rvc-core"]
        self.assertFalse(os.path.exists(eng.installing_path(self.root, comp)))

    def test_failed_uv_leaves_marker_and_not_ready(self):
        with self.assertRaises(eng.EngineError):
            self.install(["pro-env"], env={"FAKE_UV_FAIL": "--no-deps"})
        self.assertEqual(self.state("pro-env"), "partial")
        self.assertTrue(os.path.exists(os.path.join(self.root, "pro", "installing.json")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "pro", "ready.json")))
        self.install(["pro-env"])
        self.assertTrue(eng.is_ready(self.root, "pro-env"))

    def test_pro_env_runs_the_three_stages_with_constraints(self):
        log = os.path.join(self.tmp.name, "uv.log")
        self.install(["pro-env"], env={"FAKE_UV_LOG": log})
        lines = open(log).read().splitlines()
        self.assertEqual(lines[0].split()[:4], ["venv", "--relocatable", "--python", "3.11"])
        installs = [l for l in lines if l.startswith("pip install")]
        self.assertEqual(len(installs), 3)
        self.assertTrue(all(" -c " in l for l in installs))
        self.assertIn("--no-deps", installs[1])
        self.assertIn("descript-audio-codec==1.0.0", installs[1])
        self.assertIn("-r ", installs[0])
        self.assertTrue(any(e == "progress" for e, _ in self.events))

    def test_applio_layout_models_and_logs(self):
        self.install(["applio"])
        a = os.path.join(self.root, "applio")
        self.assertTrue(os.path.isfile(os.path.join(a, "core.py")))
        self.assertFalse(os.path.exists(os.path.join(a, "tabs")))
        self.assertEqual(os.readlink(os.path.join(a, "rvc", "models")), os.path.join("..", "..", "weights"))
        self.assertEqual(os.readlink(os.path.join(a, "logs")), os.path.join("..", "training"))
        self.assertTrue(os.path.isfile(os.path.join(self.root, "training", "mute", "m.npy")))
        # updating applio keeps trained voices
        os.makedirs(os.path.join(self.root, "training", "myvoice"))
        open(os.path.join(self.root, "training", "myvoice", "model.pth"), "w").write("w")
        os.remove(os.path.join(a, "ready.json"))
        self.install(["applio"])
        self.assertTrue(os.path.exists(os.path.join(self.root, "training", "myvoice", "model.pth")))

    def test_seedvc_installs_and_warms_up(self):
        self.install(["seedvc"])
        self.assertTrue(eng.is_ready(self.root, "seedvc"))
        self.assertTrue(os.path.isfile(os.path.join(self.root, "seedvc", "seed-vc", "inference.py")))
        self.assertEqual(eng.seedvc_env(self.root)["HF_HOME"], os.path.join(self.root, "seedvc", "hf"))
        sv = os.path.join(self.root, "seedvc")
        # pinned models sit in Hugging Face cache layouts, found offline through refs/main + snapshots
        snap = os.path.join(sv, "hf", "checkpoints", "models--org--dit", "snapshots", "a" * 40, "dit.pth")
        self.assertEqual(open(snap, "rb").read(), self.srv.files["/m/dit.pth"])
        self.assertEqual(open(os.path.join(sv, "hf", "checkpoints", "models--org--dit", "refs", "main")).read(), "a" * 40)
        self.assertTrue(os.path.isfile(os.path.join(sv, "hf", "hub", "models--org--voc", "snapshots", "b" * 40,
                                                    "sub", "config.json")))
        self.assertTrue(os.path.isfile(os.path.join(sv, "seed-vc", "checkpoints", "models--org--dit", "snapshots",
                                                    "a" * 40, "dit.pth")))
        # the first run happens offline
        warm = json.load(open(os.path.join(self.tmp.name, "warm_env.json")))
        self.assertEqual(warm["HF_HUB_OFFLINE"], "1")
        self.assertEqual(warm["TRANSFORMERS_OFFLINE"], "1")
        self.assertEqual(warm["HF_HOME"], os.path.join(sv, "hf"))

    def test_seedvc_model_hash_mismatch_fails_install(self):
        bad = [dict(m, files=[dict(f, sha256="0" * 64) for f in m["files"]]) for m in pins.SEEDVC_MODELS]
        with mock.patch.object(pins, "SEEDVC_MODELS", bad):
            with self.assertRaises(eng.EngineError):
                self.install(["seedvc"])
        self.assertNotEqual(self.state("seedvc"), "ready")

    def test_seedvc_warmup_timeout_fails_install(self):
        def slow(*a, **k):
            raise eng.subprocess.TimeoutExpired("x", 1)
        with mock.patch.object(eng, "_run_group", slow):
            with self.assertRaises(eng.EngineError) as cm:
                self.install(["seedvc"])
        self.assertIn("Install again", str(cm.exception))
        self.assertNotEqual(self.state("seedvc"), "ready")

    def test_child_environment_is_an_allowlist(self):
        poison = {"UV_INDEX_URL": "https://evil.example/simple", "PIP_EXTRA_INDEX_URL": "https://evil.example",
                  "HF_TOKEN": "hf_secret", "OPENAI_API_KEY": "sk-secret", "UV_EXTRA_INDEX_URL": "https://evil.example",
                  "AWS_SECRET_ACCESS_KEY": "x"}
        with mock.patch.dict(os.environ, dict(poison, HTTPS_PROXY="http://proxy.local:3128")):
            # explicit caller keys pass, poisoned ones are dropped even when the caller sends them
            self.install(["seedvc"], env=dict(poison, FAKE_UV_LOG=os.path.join(self.tmp.name, "u.log"), CNS_OK="1"))
        for dump in ("uv_env.json", "warm_env.json"):
            env = json.load(open(os.path.join(self.tmp.name, dump)))
            for k in poison:
                self.assertNotIn(k, env)
            self.assertEqual(env["PYTHONNOUSERSITE"], "1")
            self.assertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        env = json.load(open(os.path.join(self.tmp.name, "uv_env.json")))
        self.assertEqual(env["UV_CACHE_DIR"], os.path.join(self.root, ".uv-cache"))
        self.assertEqual(env["CNS_OK"], "1")
        self.assertEqual(env["HTTPS_PROXY"], "http://proxy.local:3128")   # proxy settings are passed through
        self.assertLess(len(env), 15)

    def test_uv_installs_wheels_only_with_documented_exceptions(self):
        log = os.path.join(self.tmp.name, "uv.log")
        self.install(["pro-env", "edge", "ytdlp"], env={"FAKE_UV_LOG": log})
        installs = [l for l in open(log).read().splitlines() if l.startswith("pip install")]
        self.assertEqual(len(installs), 3 + 1 + 1)
        for l in installs:
            self.assertIn("--only-binary :all:", l)
        no_bin = [l for l in installs if "--no-binary" in l]
        self.assertEqual(len(no_bin), 2)   # stage 1 (diffq) and stage 3 (argbind, randomname)
        self.assertIn("--no-binary diffq", installs[0])
        self.assertNotIn("--no-binary", installs[1])
        self.assertIn("--no-binary argbind --no-binary randomname", installs[2])
        edge = next(l for l in installs if "edge-tts==7.3.1" in l)
        self.assertIn(" -c ", edge)
        self.assertNotIn("--no-binary", edge)
        yt = next(l for l in installs if l.endswith("yt-dlp"))
        self.assertIn(" -U ", yt)
        self.assertIn(" -c ", yt)
        cons = open(os.path.join(self.root, "edge", "constraints.txt")).read()
        self.assertIn("aiohttp==", cons)

    def test_ytdlp_update_keeps_previous_ready_marker_on_failure(self):
        self.install(["ytdlp"])
        comp = eng._by_id("shared")["ytdlp"]
        self.assertTrue(eng.is_ready(self.root, "ytdlp"))
        with self.assertRaises(eng.EngineError):
            eng.update_ytdlp(self.root, self.uv, {"FAKE_UV_FAIL": "yt-dlp"}, self.emit)
        self.assertTrue(eng.is_ready(self.root, "ytdlp"))   # the old install still works: stays ready
        self.assertFalse(os.path.exists(eng.installing_path(self.root, comp)))
        eng.update_ytdlp(self.root, self.uv, {}, self.emit)
        self.assertTrue(eng.is_ready(self.root, "ytdlp"))
        self.assertIn("version", json.load(open(eng.marker_path(self.root, comp))))

    def test_safe_env_turns_uv_config_off(self):
        self.assertEqual(eng._safe_env(self.root)["UV_NO_CONFIG"], "1")

    def test_timeout_kills_the_whole_process_group(self):
        marker = os.path.join(self.tmp.name, "grandchild.pid")
        code = "import subprocess,sys,time; p=subprocess.Popen(['/bin/sleep','60']); open(sys.argv[1],'w').write(str(p.pid)); time.sleep(60)"
        with self.assertRaises(eng.subprocess.TimeoutExpired):
            eng._run_group([sys.executable, "-c", code, marker], 2)
        pid = int(open(marker).read())
        time.sleep(0.3)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_ytdlp_update_respects_offline_mode(self):
        self.install(["ytdlp"])
        with mock.patch.dict(os.environ, {"OV_OFFLINE": "1"}):
            with self.assertRaises(eng.cns_net.OfflineError):
                eng.update_ytdlp(self.root, self.uv, {}, self.emit)
        self.assertTrue(eng.is_ready(self.root, "ytdlp"))

    def test_peak_gb_matches_the_plan(self):
        want = {"infer": 3.4, "seedvc": 4.0, "train": 10.0, "train_b2": 8.2, "realtime": 2.7, "mdx": 6.5,
                "roformer": 6.6, "blend": 1.0, "ytdlp": 0.3, "edge": 0.3}
        for k, v in want.items():
            self.assertEqual(eng.status(self.root)["peak_gb"][k], v)

    def test_edge_has_its_own_environment(self):
        log = os.path.join(self.tmp.name, "uv.log")
        self.install(["edge"], env={"FAKE_UV_LOG": log})
        self.assertTrue(eng.is_ready(self.root, "edge"))
        self.assertFalse(eng.is_ready(self.root, "pro-env"))
        self.assertIn("edge-tts==7.3.1", open(log).read())
        self.assertTrue(os.path.exists(os.path.join(self.root, "edge", ".venv", "bin", "python")))

    def test_offline_mode_blocks_install_unless_explicit_download(self):
        import cns_net
        with mock.patch.dict(os.environ, {"OV_OFFLINE": "1"}):
            with self.assertRaises(cns_net.OfflineError):
                self.install(["rvc-fcpe"])
            self.install(["rvc-fcpe"], explicit_download=True)
        self.assertTrue(eng.is_ready(self.root, "rvc-fcpe"))


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_extract(self, members, file_pins):
        tar = os.path.join(self.tmp.name, "t.tgz")
        with open(tar, "wb") as f:
            f.write(make_tar(members))
        dest = os.path.join(self.tmp.name, "out")
        os.makedirs(dest, exist_ok=True)
        eng.extract_applio(tar, dest, file_pins)
        return dest

    def test_extract_only_allowed_paths(self):
        good = {"core.py": b"c", "rvc/a.py": b"a"}
        members = {"top/" + k: v for k, v in good.items()}
        members["top/tabs/app.py"] = b"gradio"
        members["top/app.py"] = b"x"
        dest = self.run_extract(members, {k: sha(v) for k, v in good.items()})
        self.assertEqual(sorted(os.listdir(dest)), ["core.py", "rvc"])
        self.assertFalse(os.path.exists(os.path.join(dest, "tabs")))

    def test_extract_rejects_traversal_and_links(self):
        pin = {"core.py": sha(b"c")}
        with self.assertRaises(eng.EngineError):
            self.run_extract({"top/core.py": b"c", "../x": b"evil"}, pin)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "x")))
        with self.assertRaises(eng.EngineError):
            self.run_extract({"top/core.py": b"c", "top/rvc/link": ("link", "/etc/passwd")}, pin)
        with self.assertRaises(eng.EngineError):
            self.run_extract({"top/core.py": b"c", "/abs/x": b"evil"}, pin)

    def test_member_larger_than_its_pinned_size_is_rejected(self):
        tar = os.path.join(self.tmp.name, "t.tgz")
        with open(tar, "wb") as f:
            f.write(make_tar({"top/core.py": b"c" * 5000}))
        dest = os.path.join(self.tmp.name, "out")
        os.makedirs(dest)
        with self.assertRaises(eng.EngineError) as cm:
            eng.extract_pinned(tar, dest, {"core.py": sha(b"c" * 5000)}, {"core.py": 10})
        self.assertIn("size", str(cm.exception))
        self.assertFalse(os.path.exists(os.path.join(dest, "core.py")))
        eng.extract_pinned(tar, dest, {"core.py": sha(b"c" * 5000)}, {"core.py": 5000})

    def test_applio_file_hashes_checked(self):
        with self.assertRaises(eng.EngineError) as cm:
            self.run_extract({"top/core.py": b"tampered"}, {"core.py": sha(b"c")})
        self.assertIn("core.py", str(cm.exception))
        with self.assertRaises(eng.EngineError):   # a pinned file missing from the archive
            self.run_extract({"top/other.py": b"c"}, {"core.py": sha(b"c")})


class UninstallTests(Base):
    def test_uninstall_frees_bytes_and_clears_ready(self):
        self.install(["rvc-core", "rvc-train-40k", "applio"])
        total = sum(e["size"] for e in pins.WEIGHTS["rvc-core"])
        freed = eng.uninstall(self.root, ["rvc-core"])
        self.assertGreaterEqual(freed, total)
        self.assertFalse(eng.is_ready(self.root, "rvc-core"))
        self.assertEqual(self.state("rvc-core"), "notinstalled")
        self.assertFalse(os.path.exists(os.path.join(self.root, "weights", "rvc-core", "a.bin")))
        self.assertTrue(eng.is_ready(self.root, "rvc-train-40k"))

    def test_cannot_remove_pro_env_while_applio_installed(self):
        self.install(["applio"])
        with self.assertRaises(eng.EngineError) as cm:
            eng.uninstall(self.root, ["pro-env"])
        self.assertIn("applio", str(cm.exception))
        self.assertTrue(eng.is_ready(self.root, "pro-env"))
        freed = eng.uninstall(self.root, ["applio", "pro-env"])
        self.assertGreater(freed, 0)
        self.assertEqual(self.state("pro-env"), "notinstalled")

    def test_uninstall_keeps_trained_voices(self):
        self.install(["applio"])
        os.makedirs(os.path.join(self.root, "training", "v"))
        open(os.path.join(self.root, "training", "v", "m.pth"), "w").write("w")
        eng.uninstall(self.root, ["applio"])
        self.assertTrue(os.path.exists(os.path.join(self.root, "training", "v", "m.pth")))


class LayoutTests(Base):
    def test_split_layout_adds_applio_env_without_installing_torch(self):
        os.makedirs(self.root)
        json.dump({"layout": "split"}, open(os.path.join(self.root, "engines.json"), "w"))
        st = eng.status(self.root)
        self.assertEqual(st["layout"], "split")
        ids = [c["id"] for c in st["components"]]
        self.assertIn("applio-env", ids)
        self.assertLess(ids.index("pro-env"), ids.index("applio"))
        log = os.path.join(self.tmp.name, "uv.log")
        self.install(["applio"], env={"FAKE_UV_LOG": log})
        self.assertTrue(eng.is_ready(self.root, "applio-env"))
        self.assertTrue(eng.is_ready(self.root, "applio"))
        self.assertFalse(eng.is_ready(self.root, "pro-env"))   # Seed-VC's env is not needed for Applio
        self.assertTrue(eng.python_for(self.root, "rvc-core").endswith("applio-env/.venv/bin/python"))
        self.assertTrue(eng.python_for(self.root, "seedvc").endswith("pro/.venv/bin/python"))
        self.assertIn("torch==2.11.0", pins.APPLIO_STRICT_CONSTRAINTS)

    def test_shared_is_the_default(self):
        self.assertEqual(eng.LAYOUT_DEFAULT, "shared")
        st = eng.status(self.root)
        self.assertEqual(st["layout"], "shared")
        self.assertNotIn("applio-env", [c["id"] for c in st["components"]])


class SystemTests(unittest.TestCase):
    VM = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Pages active:                            100000.
Pages inactive:                           50000.
Pages speculative:                         2000.
Pages throttled:                              0.
Pages wired down:                         60000.
Pages purgeable:                           3000.
"Translation faults":                  999999.
"""
    SWAP = "vm.swapusage: total = 4096.00M  used = 2048.50M  free = 2047.50M  (encrypted)\n"

    def test_memory_report_parses_vm_stat_and_swap(self):
        r = eng.memory_report(self.VM, self.SWAP, 16 << 30)
        self.assertAlmostEqual(r["free_gb"], (12345 + 50000 + 3000 + 2000) * 16384 / 2 ** 30, places=2)
        self.assertAlmostEqual(r["swap_used_gb"], 2048.5 / 1024, places=2)
        self.assertEqual(r["pressure"], "warning")
        calm = eng.memory_report(self.VM.replace("12345", "400000"), "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M\n", 16 << 30)
        self.assertEqual(calm["pressure"], "normal")
        bad = eng.memory_report(self.VM.replace("12345", "10"), "vm.swapusage: total = 9.00G  used = 6.00G  free = 3.00G\n", 16 << 30)
        self.assertEqual(bad["pressure"], "critical")
        self.assertAlmostEqual(bad["swap_used_gb"], 6.0)

    def test_sandbox_profile_denies_network_and_limits_writes(self):
        with tempfile.TemporaryDirectory() as d:
            p = eng.sandbox_profile(True, [d])
            self.assertIn("(allow default)", p)
            self.assertIn('(string=? "deny-ip" "deny-ip")', p)
            self.assertIn('(subpath "%s")' % os.path.realpath(d), p)
            self.assertLess(p.index("(deny file-write*)"), p.index("(allow file-write*"))
            self.assertIn('(string=? "allow" "deny-ip")', eng.sandbox_profile(False, [d]))
            tricky = os.path.join(d, 'a"b')
            self.assertIn('a\\"b', eng.sandbox_profile(True, [tricky]))
            with self.assertRaises(eng.EngineError):
                eng.sandbox_profile(True, ["relative/path"])
            with self.assertRaises(eng.EngineError):
                eng.sandbox_profile(True, [d + "\n(allow network*)"])

    @unittest.skipUnless(sys.platform == "darwin" and os.path.exists("/usr/bin/sandbox-exec"), "needs macOS sandbox-exec")
    def test_sandbox_profile_is_accepted_by_sandbox_exec(self):
        with tempfile.TemporaryDirectory() as d:
            import subprocess
            prof = eng.sandbox_profile(True, [d])
            ok = subprocess.run(["/usr/bin/sandbox-exec", "-p", prof, "/usr/bin/touch", os.path.join(d, "f")],
                                capture_output=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            home_file = "/tmp/cns-sandbox-outside-%d" % os.getpid()
            bad = subprocess.run(["/usr/bin/sandbox-exec", "-p", prof, "/usr/bin/touch", home_file], capture_output=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertFalse(os.path.exists(home_file))

    @unittest.skipUnless(sys.platform == "darwin" and os.path.exists("/usr/bin/sandbox-exec"), "needs macOS sandbox-exec")
    def test_engine_sb_smoke_bind_unix_but_no_internet_no_outside_writes(self):
        """The shared profile with NET=deny-ip: AF_UNIX bind works in WORK, IP is refused, writes outside are refused."""
        import subprocess
        outside = "/tmp/cns-sb-smoke-%d" % os.getpid()
        with tempfile.TemporaryDirectory() as d:
            work = os.path.join(os.path.realpath(d), "w")
            os.makedirs(work)
            code = (
                "import socket,os\n"
                "os.chdir(%r)\n"
                "s=socket.socket(socket.AF_UNIX); s.bind('u.sock'); print('bind-ok')\n"
                "try:\n socket.create_connection(('1.1.1.1',443),2); print('connected')\n"
                "except OSError: print('ip-blocked')\n"
                "try:\n open(%r,'w').write('x'); print('wrote')\n"
                "except OSError: print('write-blocked')\n" % (work, outside))
            cmd = eng.sandbox_command("deny-ip", work, None, []) + [sys.executable, "-c", code]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.stdout.split(), ["bind-ok", "ip-blocked", "write-blocked"], r.stdout + r.stderr)
        self.assertFalse(os.path.exists(outside))

    def test_sandbox_command_fails_closed(self):
        old = eng.SANDBOX_EXEC
        eng.SANDBOX_EXEC = "/nonexistent/sandbox-exec"
        try:
            with self.assertRaises(eng.EngineError):
                eng.sandbox_command("deny-ip", tempfile.gettempdir())
        finally:
            eng.SANDBOX_EXEC = old
        with self.assertRaises(eng.EngineError):
            eng.sandbox_params("sideways", tempfile.gettempdir())

    def test_pins_match_spike_requirements_file(self):
        spikes = HERE.parent / "tools" / "spikes"
        if not spikes.exists():
            self.skipTest("tools/spikes is not in this checkout")
        req = [l for l in (spikes / "pro-env-py311-requirements.txt").read_text().splitlines()
               if l.strip() and not l.startswith("#")]
        self.assertEqual(pins.PRO_REQUIREMENTS.split(), [l for l in req if not l.startswith("edge-tts")])
        self.assertNotIn("edge-tts", pins.PRO_REQUIREMENTS)   # Edge TTS lives in its own environment
        frz = [l.strip() for l in (spikes / "pro-env-py311-freeze.txt").read_text().splitlines() if l.strip()]
        self.assertEqual(pins.PRO_CONSTRAINTS.split(), frz)
        self.assertIn("descript-audio-codec==1.0.0", pins.PRO_STAGE2)
        self.assertIn("torch==2.8.0", pins.PRO_CONSTRAINTS)
        self.assertEqual(pins.APPLIO_COMMIT, "59c113106c0dfff647324ab1a80c286f17b51929")
        self.assertRegex(pins.HF_REV, r"^[0-9a-f]{40}$")
        for entries in pins.WEIGHTS.values():
            for e in entries:
                self.assertRegex(e["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(e["url"].startswith("https://huggingface.co/IAHispano/Applio/resolve/" + pins.HF_REV))

    def test_status_json_is_small_and_fast(self):
        with tempfile.TemporaryDirectory() as d:
            root = os.path.join(d, "engines")
            eng.status(root)
            t = time.perf_counter()
            st = eng.status(root)
            took = time.perf_counter() - t
            self.assertLess(took, 0.1)
            self.assertLess(len(json.dumps(st)), 8000)
            self.assertFalse(st["ready"])
            for key in ("layout", "ready", "components", "peak_gb", "ytdlp_version"):
                self.assertIn(key, st)
            for row in st["components"]:
                self.assertEqual(set(row), {"id", "title", "state", "download_bytes", "disk_bytes", "license", "optional"})
                self.assertIn(row["state"], ("notinstalled", "partial", "ready", "broken"))

    def test_cli_status_speaks_the_line_protocol(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            out = subprocess.run([sys.executable, str(HERE.parent / "Sources" / "cns_engines.py"), "status"],
                                 input=json.dumps({"root": d}) + "\n", capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            ev = json.loads(out.stdout.strip().splitlines()[-1])
            self.assertEqual(ev["event"], "result")
            self.assertFalse(ev["data"]["ready"])
            bad = subprocess.run([sys.executable, str(HERE.parent / "Sources" / "cns_engines.py"), "install"],
                                 input="{}\n", capture_output=True, text=True)
            self.assertEqual(bad.returncode, 1)
            self.assertEqual(json.loads(bad.stdout.strip().splitlines()[-1])["event"], "error")


if __name__ == "__main__":
    unittest.main()
