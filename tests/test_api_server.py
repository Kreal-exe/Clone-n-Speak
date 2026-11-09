"""Tests for Sources/cns_api.py: real sockets on 127.0.0.1 (ephemeral ports) and a fake backend.  Stdlib only."""
import hashlib
import hmac
import http.client
import io
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SOURCES = pathlib.Path(__file__).resolve().parent.parent / "Sources"
sys.path.insert(0, str(SOURCES))

import cns_api  # noqa: E402
from cns_api import ApiServer, Limits  # noqa: E402

KEY = "test-api-key-0123456789abcdef"
KEY_SHA = hashlib.sha256(KEY.encode()).hexdigest()
BRIDGE_HOST = "quiet-river-123.trycloudflare.com"


class FakeBackend:
    def __init__(self):
        self.submits, self.stops, self.pair_requests, self.calls = [], [], [], []
        self.snapshots = {}
        self.voices = [{"id": "anna", "name": "Anna", "language": "uk", "seconds": 12.5}]
        self.models = {"tts": ["base"], "rvc": [{"id": "model1", "name": "Model 1"}]}
        self.next_id = 1

    def submit(self, kind, params, origin):
        self.calls.append("submit")
        jid = "job%d" % self.next_id
        self.next_id += 1
        self.submits.append((kind, params, origin))
        self.snapshots[jid] = {"id": jid, "kind": kind, "state": "queued", "progress": 0, "status": "", "error": None,
                               "output": None, "origin": origin}
        return jid, None

    def stop(self, job_id):
        self.stops.append(job_id)

    def job(self, job_id, origin_prefix):
        self.calls.append("job")
        s = self.snapshots.get(job_id)
        return s if s and s["origin"] == origin_prefix else None

    def jobs(self, origin_prefix):
        return [s for s in self.snapshots.values() if s["origin"] == origin_prefix]

    def catalog(self):
        return {"voices": self.voices, "models": self.models}

    def pair_request(self, pair_id, name, code):
        self.pair_requests.append((pair_id, name, code))

    def add_job(self, jid, origin, state="running", output=None):
        self.snapshots[jid] = {"id": jid, "kind": "synthesize", "state": state, "progress": 0.5, "status": "x",
                               "error": None, "output": output, "origin": origin}


def call(port, method, path, headers=None, body=None, host=None, auth=KEY, timeout=5):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        c.putheader("Host", host or "127.0.0.1:%d" % port)
        if auth is not None:
            c.putheader("Authorization", "Bearer " + auth)
        for k, v in (headers or {}).items():
            c.putheader(k, v)
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            c.putheader("Content-Type", "application/json")
        if body is not None:
            c.putheader("Content-Length", str(len(body)))
        c.endheaders(body)
        r = c.getresponse()
        data = r.read()
        hdrs = {k.lower(): v for k, v in r.getheaders()}
        try:
            parsed = json.loads(data) if data and hdrs.get("content-type", "").startswith("application/json") else data
        except ValueError:
            parsed = data
        return r.status, hdrs, parsed
    finally:
        c.close()


def raw(port, payload, read=True, timeout=5):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        s.sendall(payload)
        if not read:
            return s
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = s.recv(4096)
            if not d:
                break
            buf += d
        return buf
    finally:
        if read:
            s.close()


class Base(unittest.TestCase):
    limits = Limits()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.uploads = os.path.join(self.tmp.name, "uploads")
        self.outputs = os.path.join(self.tmp.name, "outputs")
        self.backend = FakeBackend()
        self.events = []
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, self.limits, port=0,
                             events=self.events.append)
        self.port = self.srv.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.srv.shutdown)


class LocalListenerTests(Base):
    def test_binds_loopback_only(self):
        self.assertEqual(self.srv.local_address[0], "127.0.0.1")
        others = set()
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                if not info[4][0].startswith("127."):
                    others.add(info[4][0])
        except OSError:
            pass
        if not others:
            self.skipTest("no non-loopback IPv4 address on this machine")
        for ip in others:
            with self.assertRaises(OSError):
                socket.create_connection((ip, self.port), timeout=2).close()

    def test_port_in_use_raises(self):
        other = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, self.limits, port=self.port)
        with self.assertRaises(OSError):
            other.start()

    def test_no_key_401_wrong_key_401_right_key_200(self):
        a = call(self.port, "GET", "/v1/voices", auth=None)
        b = call(self.port, "GET", "/v1/voices", auth="wrong")
        c = call(self.port, "GET", "/v1/voices", auth=KEY[:-1])
        for r in (a, b, c):
            self.assertEqual(r[0], 401)
        self.assertEqual(a[2], b[2])
        self.assertEqual(b[2], c[2])
        strip = lambda h: {k: v for k, v in h.items() if k != "date"}
        self.assertEqual(strip(a[1]), strip(b[1]))
        self.assertEqual(strip(b[1]), strip(c[1]))
        ok = call(self.port, "GET", "/v1/voices")
        self.assertEqual(ok[0], 200)
        self.assertEqual(ok[2]["voices"][0]["id"], "anna")
        self.assertEqual(ok[1]["cache-control"], "no-store")
        self.assertEqual(ok[1]["x-content-type-options"], "nosniff")

    def test_key_compare_is_constant_time(self):
        real = hmac.compare_digest
        spy = mock.Mock(side_effect=real)
        with mock.patch.object(hmac, "compare_digest", spy):
            self.assertEqual(call(self.port, "GET", "/v1/voices")[0], 200)
            self.assertEqual(call(self.port, "GET", "/v1/voices", auth="nope")[0], 401)
        self.assertGreaterEqual(spy.call_count, 2)
        src = (SOURCES / "cns_api.py").read_text()
        self.assertIsNone(re.search(r"[!=]=\s*\(?(self\.)?_?\w*key\b", src), "plain comparison against a key")
        self.assertIsNone(re.search(r"\bkey\w*\s*[!=]=", src))

    def test_origin_header_403_and_no_cors_headers_anywhere(self):
        seen = [
            call(self.port, "GET", "/v1/voices", headers={"Origin": "https://evil.example"}),
            call(self.port, "GET", "/v1/voices", headers={"Origin": "null"}, auth=None),
            call(self.port, "OPTIONS", "/v1/voices", headers={"Origin": "https://evil.example",
                                                              "Access-Control-Request-Method": "POST"}),
            call(self.port, "GET", "/v1/voices"),
            call(self.port, "GET", "/v1/voices", auth="bad"),
            call(self.port, "GET", "/v1/nothing"),
            call(self.port, "OPTIONS", "/v1/voices"),
        ]
        self.assertEqual([s[0] for s in seen[:3]], [403, 403, 403])
        for _, hdrs, _ in seen:
            self.assertFalse([k for k in hdrs if k.startswith("access-control")], hdrs)

    def test_options_is_rejected(self):
        st, hdrs, _ = call(self.port, "OPTIONS", "/v1/voices")
        self.assertEqual(st, 405)
        self.assertNotIn("access-control-allow-methods", hdrs)
        for m in ("PUT", "DELETE", "PATCH"):
            self.assertEqual(call(self.port, m, "/v1/voices")[0], 405)

    def test_foreign_host_header_rejected(self):
        for h in ("evil.example", "evil.example:%d" % self.port, "127.0.0.1.evil.example:%d" % self.port,
                  "127.0.0.1:1"):
            self.assertEqual(call(self.port, "GET", "/v1/voices", host=h)[0], 403, h)
        self.assertEqual(call(self.port, "GET", "/v1/voices", host="localhost:%d" % self.port)[0], 200)
        self.assertEqual(raw(self.port, b"GET /v1/voices HTTP/1.1\r\n\r\n")[:12], b"HTTP/1.1 403")

    def test_oversized_json_413_without_reading_body(self):
        t0 = time.time()
        resp = raw(self.port, ("POST /v1/synthesize HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n"
                               "Content-Type: application/json\r\nContent-Length: 70000\r\n\r\n"
                               % (self.port, KEY)).encode())
        self.assertTrue(resp.startswith(b"HTTP/1.1 413"), resp[:40])
        self.assertLess(time.time() - t0, 2)          # body was never sent, never waited for

    def test_post_without_content_length_411(self):
        resp = raw(self.port, ("POST /v1/synthesize HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n\r\n"
                               % (self.port, KEY)).encode())
        self.assertTrue(resp.startswith(b"HTTP/1.1 411"), resp[:40])

    def test_chunked_rejected(self):
        resp = raw(self.port, ("POST /v1/synthesize HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n"
                               "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n" % (self.port, KEY)).encode())
        self.assertRegex(resp[:12], rb"HTTP/1.1 (411|400|501)")
        self.assertEqual(self.backend.submits, [])

    def test_upload_over_limit_413_and_nothing_left_on_disk(self):
        srv_limits = Limits(upload=1000)
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, srv_limits, port=0)
        port = self.srv.start()
        resp = raw(port, ("POST /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n"
                          "Content-Type: audio/wav\r\nContent-Length: 5000\r\n\r\n" % (port, KEY)).encode())
        self.assertTrue(resp.startswith(b"HTTP/1.1 413"))
        self.assertEqual(os.listdir(self.uploads), [])
        # a body that stops short leaves nothing either
        s = raw(port, ("POST /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n"
                       "Content-Type: audio/wav\r\nContent-Length: 900\r\n\r\n" % (port, KEY)).encode() + b"x" * 100,
                read=False)
        s.close()
        time.sleep(0.4)
        self.assertEqual(os.listdir(self.uploads), [])
        self.addCleanup(self.srv.shutdown)

    def test_upload_name_is_server_chosen(self):
        st, _, body = call(self.port, "POST", "/v1/uploads", body=b"RIFFdata" * 10,
                           headers={"Content-Type": "audio/wav", "X-Filename": "../../x",
                                    "Content-Disposition": 'attachment; filename="../../y"'})
        self.assertEqual(st, 201)
        self.assertEqual(body["bytes"], 80)
        files = os.listdir(self.uploads)
        self.assertEqual(files, [body["uploadId"] + ".bin"])
        self.assertRegex(files[0], r"^[0-9a-f-]{36}\.bin$")
        self.assertEqual(call(self.port, "POST", "/v1/uploads", body=b"x", headers={"Content-Type": "text/html"})[0], 415)

    def test_upload_quota_and_ttl(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs,
                             Limits(uploads_total=300, upload_ttl=1), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        hdr = {"Content-Type": "application/octet-stream"}
        st, _, first = call(port, "POST", "/v1/uploads", body=b"a" * 200, headers=hdr)
        self.assertEqual(st, 201)
        self.assertEqual(call(port, "POST", "/v1/uploads", body=b"a" * 200, headers=hdr)[0], 507)
        time.sleep(1.4)
        # expired: unusable, and swept (and its space freed) by the next upload
        self.assertEqual(call(port, "POST", "/v1/convert", body={"uploadId": first["uploadId"], "model": "model1"})[0], 404)
        st, _, second = call(port, "POST", "/v1/uploads", body=b"b" * 200, headers=hdr)
        self.assertEqual(st, 201)
        self.assertEqual(os.listdir(self.uploads), [second["uploadId"] + ".bin"])

    def test_job_id_format_enforced(self):
        for bad in ("..%2f..%2fetc%2fpasswd", "%00", "a" * 200, "..", "a%2fb", "a%20b"):
            self.backend.calls.clear()
            for suffix in ("", "/output"):
                self.assertEqual(call(self.port, "GET", "/v1/jobs/" + bad + suffix)[0], 404, bad)
            self.assertEqual(call(self.port, "POST", "/v1/jobs/" + bad + "/stop")[0], 404, bad)
            self.assertEqual(self.backend.calls, [], bad)
        self.assertEqual(self.backend.stops, [])

    def test_other_origin_jobs_invisible(self):
        self.backend.add_job("uijob", "ui")
        self.backend.add_job("apijob", "api")
        self.backend.add_job("devjob", "bridge:abcd")
        self.assertEqual(call(self.port, "GET", "/v1/jobs/uijob")[0], 404)
        self.assertEqual(call(self.port, "GET", "/v1/jobs/devjob")[0], 404)
        self.assertEqual(call(self.port, "POST", "/v1/jobs/uijob/stop")[0], 404)
        self.assertEqual(self.backend.stops, [])
        ids = [j["id"] for j in call(self.port, "GET", "/v1/jobs")[2]["jobs"]]
        self.assertEqual(ids, ["apijob"])
        self.assertEqual(call(self.port, "POST", "/v1/jobs/apijob/stop")[0], 202)
        self.assertEqual(self.backend.stops, ["apijob"])

    def test_job_snapshot_never_exposes_paths(self):
        out = os.path.join(self.outputs, "a.wav")
        pathlib.Path(out).write_bytes(b"RIFF....")
        self.backend.add_job("j1", "api", "done", {"name": "a.wav", "bytes": 8, "type": "audio/wav", "path": out})
        st, _, body = call(self.port, "GET", "/v1/jobs/j1")
        self.assertEqual(st, 200)
        self.assertNotIn(self.outputs, json.dumps(body))
        self.assertEqual(body["output"], {"name": "a.wav", "bytes": 8, "type": "audio/wav"})
        st, hdrs, data = call(self.port, "GET", "/v1/jobs/j1/output")
        self.assertEqual((st, data, hdrs["content-type"]), (200, b"RIFF....", "audio/wav"))

    def test_output_outside_outputs_dir_is_refused(self):
        self.backend.add_job("etc", "api", "done", {"name": "hosts", "bytes": 1, "type": "audio/wav", "path": "/etc/hosts"})
        os.symlink("/etc/hosts", os.path.join(self.outputs, "link.wav"))
        self.backend.add_job("lnk", "api", "done", {"name": "l", "bytes": 1, "type": "audio/wav",
                                                    "path": os.path.join(self.outputs, "link.wav")})
        self.backend.add_job("dot", "api", "done", {"name": "d", "bytes": 1, "type": "audio/wav",
                                                    "path": os.path.join(self.outputs, "..", "uploads", "x")})
        self.backend.add_job("dir", "api", "done", {"name": "d", "bytes": 1, "type": "audio/wav", "path": self.outputs})
        for jid in ("etc", "lnk", "dot", "dir"):
            st, _, data = call(self.port, "GET", "/v1/jobs/%s/output" % jid)
            self.assertIn(st, (404, 500), jid)
            self.assertNotIn(b"localhost", data if isinstance(data, bytes) else json.dumps(data).encode())

    def test_schema_rejects_unknown_fields_bad_types_ranges(self):
        up = call(self.port, "POST", "/v1/uploads", body=b"x" * 10, headers={"Content-Type": "audio/wav"})[2]["uploadId"]
        bad = [
            ("/v1/synthesize", {"text": "hi", "speed": 99}),
            ("/v1/synthesize", {"text": "hi", "speed": True}),
            ("/v1/synthesize", {"text": "hi", "format": "exe"}),
            ("/v1/synthesize", {"text": "hi", "voice": "../x"}),
            ("/v1/synthesize", {"text": "hi", "evil": 1}),
            ("/v1/synthesize", {"text": 5}),
            ("/v1/synthesize", {"text": ""}),
            ("/v1/synthesize", {}),
            ("/v1/synthesize", ["hi"]),
            ("/v1/synthesize", {"text": "hi", "language": "x" * 30}),
            ("/v1/convert", {"uploadId": up, "model": "model1", "params": {"f0_method": "rm"}}),
            ("/v1/convert", {"uploadId": up, "model": "model1", "params": {"pitch": 99}}),
            ("/v1/convert", {"uploadId": up, "model": "model1", "params": {"x": 1}}),
            ("/v1/convert", {"uploadId": "../../etc/passwd", "model": "model1"}),
            ("/v1/convert", {"uploadId": up}),
            ("/v1/convert", {"uploadId": up, "model": "model1", "voice": "anna"}),
            ("/v1/clone", {"name": "x\x00y", "uploadId": up, "consent": True}),
            ("/v1/clone", {"name": "x", "uploadId": up, "consent": "yes"}),
        ]
        for path, body in bad:
            st, _, resp = call(self.port, "POST", path, body=body)
            self.assertEqual(st, 400, (path, body, resp))
        self.assertEqual(call(self.port, "POST", "/v1/synthesize", body=b"{not json")[0], 400)
        self.assertEqual(call(self.port, "POST", "/v1/synthesize", body={"text": "hi", "voice": "ghost"})[0], 404)
        self.assertEqual(self.backend.submits, [])
        ok = call(self.port, "POST", "/v1/synthesize",
                  body={"text": "hi", "voice": "anna", "speed": 1.2, "format": "m4a", "language": "uk"})
        self.assertEqual(ok[0], 202)
        self.assertEqual(self.backend.submits[0][2], "api")
        ok = call(self.port, "POST", "/v1/convert",
                  body={"uploadId": up, "model": "model1", "params": {"pitch": -3, "f0_method": "rmvpe"}})
        self.assertEqual(ok[0], 202, ok)
        kind, params, _ = self.backend.submits[1]
        self.assertTrue(params["uploadPath"].startswith(self.uploads))

    def test_text_limit(self):
        self.assertEqual(call(self.port, "POST", "/v1/synthesize", body={"text": "a" * 20000})[0], 202)
        self.assertEqual(call(self.port, "POST", "/v1/synthesize", body={"text": "a" * 20001})[0], 400)

    def test_clone_requires_consent_true(self):
        up = call(self.port, "POST", "/v1/uploads", body=b"x" * 10, headers={"Content-Type": "audio/wav"})[2]["uploadId"]
        for body in ({"name": "V", "uploadId": up}, {"name": "V", "uploadId": up, "consent": False}):
            st, _, resp = call(self.port, "POST", "/v1/clone", body=body)
            self.assertEqual(st, 400)
            self.assertIn("consent", resp["error"])
        self.assertEqual(self.backend.submits, [])
        self.assertEqual(call(self.port, "POST", "/v1/clone", body={"name": "V", "uploadId": up, "consent": True})[0], 202)
        self.assertEqual(self.backend.submits[0][0], "clone")

    def test_active_job_cap_429(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(active_jobs=2), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        self.backend.add_job("a", "api", "running")
        self.backend.add_job("b", "api", "queued")
        self.backend.add_job("c", "api", "done")
        st, hdrs, _ = call(port, "POST", "/v1/synthesize", body={"text": "hi"})
        self.assertEqual(st, 429)
        self.assertIn("retry-after", hdrs)
        self.backend.snapshots["a"]["state"] = "done"
        self.assertEqual(call(port, "POST", "/v1/synthesize", body={"text": "hi"})[0], 202)

    def test_rate_limit_429_with_retry_after(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(rate_per_s=2, burst=5), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        codes = [call(port, "GET", "/v1/voices") for _ in range(12)]
        limited = [c for c in codes if c[0] == 429]
        self.assertTrue(limited)
        self.assertEqual(codes[0][0], 200)
        self.assertTrue(int(limited[0][1]["retry-after"]) >= 1)

    def test_bad_auth_lockout_never_blocks_correct_key(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(bad_auth_per_min=3), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        codes = [call(port, "GET", "/v1/voices", auth="guess%d" % i)[0] for i in range(8)]
        self.assertEqual(codes[:3], [401, 401, 401])
        self.assertEqual(set(codes[4:]), {429})
        self.assertEqual(call(port, "GET", "/v1/voices")[0], 200)

    def test_connection_cap_503(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs,
                             Limits(connections=3, socket_timeout=5), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        idle = [socket.create_connection(("127.0.0.1", port)) for _ in range(3)]
        try:
            time.sleep(0.3)
            resp = raw(port, b"GET /v1/voices HTTP/1.1\r\n\r\n")
            self.assertTrue(resp.startswith(b"HTTP/1.1 503"), resp[:30])
        finally:
            for s in idle:
                s.close()
        time.sleep(0.3)
        self.assertEqual(call(port, "GET", "/v1/voices")[0], 200)

    def test_slow_client_times_out(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(socket_timeout=1), port=0)
        port = self.srv.start()
        self.addCleanup(self.srv.shutdown)
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(b"GET /v1/voices HTTP/1.1\r\nHost: 127.0")
        t0 = time.time()
        data = s.recv(100)                     # server drops the connection
        self.assertEqual(data, b"")
        self.assertLess(time.time() - t0, 3.5)
        s.close()
        # body stalls halfway: also dropped, nothing submitted
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(("POST /v1/synthesize HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer %s\r\n"
                   "Content-Length: 50\r\n\r\n{\"text\":" % (port, KEY)).encode())
        self.assertIn(s.recv(200)[:12], (b"HTTP/1.1 400", b""))
        s.close()
        self.assertEqual(self.backend.submits, [])

    def test_server_logs_never_contain_key(self):
        buf = io.StringIO()
        with mock.patch.object(sys, "stderr", buf):
            call(self.port, "GET", "/v1/voices")
            call(self.port, "GET", "/v1/voices?key=" + KEY, auth="other-secret-token")
            call(self.port, "POST", "/v1/synthesize", body={"text": "private words"})
            call(self.port, "GET", "/v1/jobs/" + "z" * 100)
            raw(self.port, b"GARBAGE\r\n\r\n")
            time.sleep(0.2)
        out = buf.getvalue()
        self.assertTrue(out)                     # it does log
        for secret in (KEY, KEY_SHA, "other-secret-token", "Bearer", "private words"):
            self.assertNotIn(secret, out)

    def test_bridge_routes_absent_on_local_listener(self):
        self.assertEqual(call(self.port, "POST", "/bridge/pair", body={"name": "x"}, auth=None)[0], 401)
        self.assertEqual(call(self.port, "POST", "/bridge/pair", body={"name": "x"})[0], 404)

    def test_shutdown_on_stdin_eof(self):
        p = subprocess.Popen([sys.executable, str(SOURCES / "cns_api.py")], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        cfg = {"op": "config", "port": 0, "key_sha256": KEY_SHA, "uploads_dir": self.uploads, "outputs_dir": self.outputs}
        p.stdin.write((json.dumps(cfg) + "\n").encode())
        p.stdin.flush()
        ev = json.loads(p.stdout.readline())
        self.assertEqual(ev["op"], "listening")
        port = ev["port"]
        self.assertEqual(call(port, "GET", "/v1/voices")[0], 200)
        t0 = time.time()
        p.stdin.close()
        p.wait(timeout=2)
        self.assertLess(time.time() - t0, 2)
        self.assertEqual(p.returncode, 0)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
        p.stdout.close()

    def test_stdio_protocol_roundtrip(self):
        p = subprocess.Popen([sys.executable, str(SOURCES / "cns_api.py")], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (p.kill(), p.wait(), p.stdin.close() if not p.stdin.closed else None, p.stdout.close()))

        def send(o):
            p.stdin.write((json.dumps(o) + "\n").encode())
            p.stdin.flush()
        send({"op": "config", "port": 0, "key_sha256": KEY_SHA, "uploads_dir": self.uploads,
              "outputs_dir": self.outputs, "limits": {"rate_per_s": 100, "evil": 1},
              "voices": [{"id": "anna", "name": "Anna", "language": "uk", "seconds": 1}],
              "models": {"tts": [], "rvc": []}})
        port = json.loads(p.stdout.readline())["port"]
        self.assertEqual(call(port, "GET", "/v1/voices")[2]["voices"][0]["id"], "anna")
        result = {}
        t = threading.Thread(target=lambda: result.update(r=call(port, "POST", "/v1/synthesize", body={"text": "hi"})))
        t.start()
        sub = json.loads(p.stdout.readline())
        self.assertEqual((sub["op"], sub["kind"], sub["origin"]), ("submit", "synthesize", "api"))
        send({"op": "submitted", "reqId": sub["reqId"], "jobId": "jobx1"})
        t.join(5)
        self.assertEqual(result["r"][0], 202)
        send({"op": "job", "job": {"id": "jobx1", "kind": "synthesize", "state": "done", "progress": 1, "status": "",
                                   "error": None, "origin": "api", "output": None}})
        time.sleep(0.2)
        self.assertEqual(call(port, "GET", "/v1/jobs/jobx1")[2]["state"], "done")
        call(port, "POST", "/v1/jobs/jobx1/stop")
        self.assertEqual(json.loads(p.stdout.readline()), {"op": "stop", "jobId": "jobx1"})
        send({"op": "quit"})
        p.wait(timeout=3)


class BridgeTests(Base):
    def setUp(self):
        super().setUp()
        self.bport = self.srv.start_bridge(BRIDGE_HOST)

    def bcall(self, method, path, **kw):
        kw.setdefault("host", BRIDGE_HOST)
        return call(self.bport, method, path, **kw)

    def pair(self, name="Phone", approve=True):
        st, _, body = self.bcall("POST", "/bridge/pair", body={"name": name}, auth=None)
        self.assertEqual(st, 201, body)
        if approve is None:
            return body, None
        self.srv.decide_pair(body["pairId"], approve)
        st, _, got = self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)
        return body, got.get("deviceToken")

    def test_bridge_listener_rejects_wrong_host(self):
        self.assertEqual(self.srv.bridge_address[0], "127.0.0.1")
        for h in ("evil.example", "127.0.0.1:%d" % self.bport, "localhost:%d" % self.bport):
            self.assertEqual(self.bcall("GET", "/v1/voices", host=h)[0], 403, h)
            self.assertEqual(self.bcall("POST", "/bridge/pair", body={"name": "x"}, host=h, auth=None)[0], 403, h)
        self.assertEqual(self.bcall("GET", "/v1/voices", host=BRIDGE_HOST + ":443", auth="x")[0], 401)
        self.srv.core.bridge_host = None                # host not set: everything is refused
        self.assertEqual(self.bcall("GET", "/v1/voices", host=BRIDGE_HOST)[0], 403)
        self.assertEqual(self.bcall("POST", "/bridge/pair", body={"name": "x"}, auth=None)[0], 403)
        self.assertEqual(self.bcall("GET", "/v1/voices", host="None")[0], 403)
        self.srv.core.bridge_host = BRIDGE_HOST
        self.assertEqual(self.bcall("GET", "/v1/voices", headers={"Origin": "https://x"}, auth="x")[0], 403)

    def test_local_key_not_accepted_on_bridge_and_device_token_not_on_local(self):
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=KEY)[0], 401)
        _, tok = self.pair()
        self.assertTrue(tok)
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=tok)[0], 200)
        self.assertEqual(call(self.port, "GET", "/v1/voices", auth=tok)[0], 401)
        self.assertEqual(self.bcall("GET", "/bridge/pair/x", auth=None)[0], 404)

    def test_unpaired_device_gets_nothing(self):
        for path in ("/v1/voices", "/v1/models", "/v1/jobs", "/v1/jobs/abc"):
            self.assertEqual(self.bcall("GET", path, auth=None)[0], 401, path)
        self.assertEqual(self.bcall("POST", "/v1/synthesize", body={"text": "hi"}, auth=None)[0], 401)
        self.assertEqual(self.bcall("POST", "/v1/uploads", body=b"x", auth="guess")[0], 401)
        self.assertEqual(self.backend.submits, [])

    def test_pair_flow_requires_mac_approval(self):
        body, _ = self.pair(approve=None)
        self.assertRegex(body["code"], r"^[0-9]{6}$")
        self.assertEqual(self.backend.pair_requests, [(body["pairId"], "Phone", body["code"])])
        st, _, got = self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)
        self.assertEqual((st, got), (200, {"status": "pending"}))
        self.assertEqual(self.events, [])
        self.srv.decide_pair(body["pairId"], True)
        st, _, got = self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)
        tok = got["deviceToken"]
        self.assertEqual(got["status"], "approved")
        self.assertGreaterEqual(len(tok), 43)
        again = self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)[2]
        self.assertNotIn("deviceToken", again)
        added = [e for e in self.events if e["op"] == "device_added"]
        self.assertEqual(len(added), 1)
        self.assertEqual(added[0]["token_sha256"], hashlib.sha256(tok.encode()).hexdigest())
        self.assertNotIn(tok, json.dumps(self.events))
        self.srv.decide_pair(body["pairId"], False)       # a decided pairing cannot be flipped
        self.assertEqual(self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)[2]["status"], "approved")
        self.assertEqual(self.bcall("GET", "/bridge/pair/unknown-id-1234", auth=None)[0], 404)

    def test_pair_denied_and_expired(self):
        body, tok = self.pair(approve=False)
        self.assertIsNone(tok)
        st, _, got = self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)
        self.assertEqual(got, {"status": "denied"})
        self.assertEqual([e for e in self.events if e["op"] == "device_added"], [])
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(pair_ttl=1), port=0)
        self.srv.start()
        self.bport = self.srv.start_bridge(BRIDGE_HOST)
        self.addCleanup(self.srv.shutdown)
        body, _ = self.pair(approve=None)
        time.sleep(1.3)
        self.assertEqual(self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)[2], {"status": "expired"})
        self.srv.decide_pair(body["pairId"], True)        # too late
        self.assertEqual(self.bcall("GET", "/bridge/pair/" + body["pairId"], auth=None)[2], {"status": "expired"})
        self.assertEqual(self.srv.core.devices, [])

    def test_pair_pending_cap_and_rate_limit(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs,
                             Limits(pair_pending=2, pair_per_min=3), port=0)
        self.srv.start()
        self.bport = self.srv.start_bridge(BRIDGE_HOST)
        self.addCleanup(self.srv.shutdown)
        a, _ = self.pair(approve=None)
        self.pair(approve=None)
        st, hdrs, _ = self.bcall("POST", "/bridge/pair", body={"name": "c"}, auth=None)
        self.assertEqual(st, 429)
        self.assertIn("retry-after", hdrs)
        self.srv.decide_pair(a["pairId"], False)           # frees a pending slot
        self.assertEqual(self.bcall("POST", "/bridge/pair", body={"name": "d"}, auth=None)[0], 201)
        # per-minute budget (3) now spent
        self.srv.decide_pair(self.backend.pair_requests[1][0], False)
        st, hdrs, _ = self.bcall("POST", "/bridge/pair", body={"name": "e"}, auth=None)
        self.assertEqual(st, 429)
        self.assertGreaterEqual(int(hdrs["retry-after"]), 1)

    def test_revoked_device_401(self):
        _, tok = self.pair()
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=tok)[0], 200)
        dev = [e for e in self.events if e["op"] == "device_added"][0]
        self.srv.revoke(dev["id"])
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=tok)[0], 401)
        # a restart restores devices from the stored hashes only
        self.srv.set_devices([{"id": dev["id"], "name": dev["name"], "token_sha256": dev["token_sha256"]}])
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=tok)[0], 200)
        self.srv.stop_bridge()
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", self.bport), timeout=1).close()

    def test_device_name_sanitized(self):
        self.pair(name="ev\x00il\x1b[31m\nname‮" + "x" * 150, approve=None)
        name = self.backend.pair_requests[0][1]
        self.assertLessEqual(len(name), 40)
        self.assertTrue(name.isprintable(), repr(name))
        self.assertNotIn("\x1b", name)
        self.assertEqual(self.bcall("POST", "/bridge/pair", body={"name": "x", "extra": 1}, auth=None)[0], 400)
        self.pair(name="\x00\x01", approve=None)
        self.assertEqual(self.backend.pair_requests[1][1], "Device")

    def test_bridge_upload_limit_is_smaller(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs,
                             Limits(upload=2000, bridge_upload=500), port=0)
        lport = self.srv.start()
        self.bport = self.srv.start_bridge(BRIDGE_HOST)
        self.addCleanup(self.srv.shutdown)
        _, tok = self.pair()
        hdr = {"Content-Type": "audio/wav"}
        self.assertEqual(call(lport, "POST", "/v1/uploads", body=b"x" * 1000, headers=hdr)[0], 201)
        resp = raw(self.bport, ("POST /v1/uploads HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\n"
                                "Content-Type: audio/wav\r\nContent-Length: 1000\r\n\r\n" % (BRIDGE_HOST, tok)).encode())
        self.assertTrue(resp.startswith(b"HTTP/1.1 413"))
        self.assertEqual(self.bcall("POST", "/v1/uploads", body=b"x" * 400, auth=tok, headers=hdr)[0], 201)

    def test_bridge_jobs_scoped_to_device(self):
        _, tok_a = self.pair("A")
        _, tok_b = self.pair("B")
        dev_a, dev_b = [e["id"] for e in self.events if e["op"] == "device_added"]
        st, _, sub = self.bcall("POST", "/v1/synthesize", body={"text": "hi"}, auth=tok_a)
        self.assertEqual(st, 202)
        self.assertEqual(self.backend.submits[-1][2], "bridge:" + dev_a)
        self.backend.add_job("bjob", "bridge:" + dev_b)
        self.assertEqual(self.bcall("GET", "/v1/jobs/" + sub["jobId"], auth=tok_a)[0], 200)
        self.assertEqual(self.bcall("GET", "/v1/jobs/" + sub["jobId"], auth=tok_b)[0], 404)
        self.assertEqual(self.bcall("GET", "/v1/jobs/bjob", auth=tok_a)[0], 404)
        self.assertEqual(self.bcall("POST", "/v1/jobs/bjob/stop", auth=tok_a)[0], 404)
        self.assertEqual([j["id"] for j in self.bcall("GET", "/v1/jobs", auth=tok_a)[2]["jobs"]], [sub["jobId"]])
        self.assertEqual([j["id"] for j in self.bcall("GET", "/v1/jobs", auth=tok_b)[2]["jobs"]], ["bjob"])
        self.assertEqual([j["id"] for j in call(self.port, "GET", "/v1/jobs")[2]["jobs"]], [])
        # uploads are scoped too
        up = self.bcall("POST", "/v1/uploads", body=b"x" * 10, auth=tok_a, headers={"Content-Type": "audio/wav"})[2]
        body = {"uploadId": up["uploadId"], "model": "model1"}
        self.assertEqual(self.bcall("POST", "/v1/convert", body=body, auth=tok_b)[0], 404)
        self.assertEqual(self.bcall("POST", "/v1/convert", body=body, auth=tok_a)[0], 202)
        self.assertEqual(call(self.port, "POST", "/v1/convert", body=body)[0], 404)

    def test_bridge_rate_limit_is_per_device(self):
        self.srv.shutdown()
        self.srv = ApiServer(self.backend, KEY_SHA, self.uploads, self.outputs, Limits(bridge_rate_per_s=1), port=0)
        self.srv.start()
        self.bport = self.srv.start_bridge(BRIDGE_HOST)
        self.addCleanup(self.srv.shutdown)
        _, tok_a = self.pair("A")
        _, tok_b = self.pair("B")
        codes = [self.bcall("GET", "/v1/voices", auth=tok_a)[0] for _ in range(8)]
        self.assertIn(429, codes)
        self.assertEqual(self.bcall("GET", "/v1/voices", auth=tok_b)[0], 200)


if __name__ == "__main__":
    unittest.main()
