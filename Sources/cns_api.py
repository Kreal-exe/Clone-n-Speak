"""Clone'n'Speak local HTTP API and Bridge listener (stdlib only).

Two listeners share one core:
  * the local listener on 127.0.0.1:<port>, authenticated by the API key (only its SHA-256 is known here);
  * the Bridge listener on 127.0.0.1:<ephemeral>, reached through a tunnel, authenticated by per-device
    tokens (only their SHA-256 is stored) and accepting only the tunnel's Host header.

The server validates and forwards; the app does the work through a Backend.  Nothing in a request is ever
turned into a filesystem path: clients name jobId / uploadId / voice / model, and the server looks these up
in its own tables.  Process protocol (main): one JSON object per line on stdin / stdout, logs on stderr.
"""
from __future__ import annotations

import dataclasses
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import unicodedata
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Optional, Protocol, Tuple


@dataclasses.dataclass(frozen=True)
class Limits:
    json_body: int = 64 * 1024
    upload: int = 50 * 1024 * 1024
    bridge_upload: int = 25 * 1024 * 1024
    text_chars: int = 20000
    active_jobs: int = 8
    uploads_total: int = 500 * 1024 * 1024
    upload_ttl: int = 3600
    rate_per_s: int = 20
    burst: int = 40
    bad_auth_per_min: int = 10
    connections: int = 16
    socket_timeout: int = 10
    pair_pending: int = 3
    pair_per_min: int = 5
    pair_ttl: int = 120
    bridge_rate_per_s: int = 5
    min_upload_bytes_per_s: int = 65536     # slower senders are dropped after the grace period
    pair_json_body: int = 2048


class Backend(Protocol):
    def submit(self, kind: str, params: dict, origin: str) -> Tuple[Optional[str], Optional[str]]: ...
    def stop(self, job_id: str) -> None: ...
    def job(self, job_id: str, origin_prefix: str) -> Optional[dict]: ...
    def jobs(self, origin_prefix: str) -> list: ...
    def catalog(self) -> dict: ...
    def pair_request(self, pair_id: str, name: str, code: str) -> None: ...


# ---------------------------------------------------------------- schemas

JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
UPLOAD_ID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
PAIR_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
NAME_ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")   # voice / model ids
LANG_RE = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$")
MOOD_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
F0_METHODS = ("rmvpe", "crepe", "crepe-tiny", "fcpe", "harvest", "pm", "dio")
OUTPUT_TYPES = {"audio/wav", "audio/x-wav", "audio/mp4", "audio/flac", "audio/mpeg", "audio/x-m4a", "audio/ogg"}
ACTIVE_STATES = ("queued", "running", "starting")

# field: (kind, required, constraint).  kinds: str, id, int, num, bool, enum, obj.  additionalProperties: false.
SCHEMAS = {
    "synthesize": {
        "text": ("str", True, (1, "text_chars")),
        "voice": ("id", False, None),
        "language": ("re", False, LANG_RE),
        "mood": ("re", False, MOOD_RE),
        "speed": ("num", False, (0.5, 2.0)),
        "format": ("enum", False, ("wav", "m4a", "flac")),
    },
    "clone": {
        "name": ("str", True, (1, 60)),
        "uploadId": ("re", True, UPLOAD_ID_RE),
        "ref_text": ("str", False, (0, 2000)),
        "language": ("re", False, LANG_RE),
        "consent": ("bool", False, None),
    },
    "convert": {
        "uploadId": ("re", True, UPLOAD_ID_RE),
        "model": ("id", False, None),
        "voice": ("id", False, None),
        "params": ("obj", False, {
            "pitch": ("num", False, (-24, 24)),
            "index_rate": ("num", False, (0.0, 1.0)),
            "protect": ("num", False, (0.0, 0.5)),
            "f0_method": ("enum", False, F0_METHODS),
        }),
    },
    "pair": {"name": ("raw", True, (1, 200))},   # sanitized afterwards, not rejected
}


def _has_control(s: str) -> bool:
    return any(unicodedata.category(c).startswith("C") for c in s)


def validate(schema: dict, data, limits: Limits, path: str = ""):
    """Return an error string or None.  Unknown fields, wrong types and out-of-range values are rejected."""
    if not isinstance(data, dict):
        return "body must be a JSON object"
    for k in data:
        if k not in schema:
            return "unknown field: %s%s" % (path, str(k)[:40])
    for k, (kind, required, con) in schema.items():
        if k not in data:
            if required:
                return "missing field: %s%s" % (path, k)
            continue
        v = data[k]
        where = path + k
        if kind in ("str", "raw"):
            if not isinstance(v, str):
                return "%s must be a string" % where
            lo, hi = con
            hi = getattr(limits, hi) if isinstance(hi, str) else hi
            if not lo <= len(v) <= hi:
                return "%s length must be %d..%d" % (where, lo, hi)
            if kind == "str" and k == "name" and (_has_control(v) or not v.strip()):
                return "%s has invalid characters" % where
        elif kind == "id":
            if not isinstance(v, str) or not NAME_ID_RE.match(v):
                return "%s has invalid format" % where
        elif kind == "re":
            if not isinstance(v, str) or not con.match(v):
                return "%s has invalid format" % where
        elif kind == "num":
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
                return "%s must be a number" % where
            if not con[0] <= v <= con[1]:
                return "%s must be within %s..%s" % (where, con[0], con[1])
        elif kind == "bool":
            if not isinstance(v, bool):
                return "%s must be a boolean" % where
        elif kind == "enum":
            if not isinstance(v, str) or v not in con:
                return "%s must be one of %s" % (where, ", ".join(con))
        elif kind == "obj":
            err = validate(con, v, limits, where + ".")
            if err:
                return err
    return None


# ---------------------------------------------------------------- helpers

def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()


def sanitize_device_name(name) -> str:
    s = "".join(c if not unicodedata.category(c).startswith("C") else " " for c in str(name))
    s = " ".join(s.split())[:40].strip()
    return s or "Device"


def _scrub(obj, depth=0):
    """Make a catalog JSON-safe and drop anything path-like."""
    if depth > 6:
        return None
    if isinstance(obj, dict):
        return {str(k): _scrub(v, depth + 1) for k, v in obj.items()
                if str(k).lower() not in ("path", "file", "dir", "url", "folder")}
    if isinstance(obj, (list, tuple)):
        return [_scrub(v, depth + 1) for v in obj][:500]
    if isinstance(obj, (str, int, float, bool)) or obj is None:
        return obj
    return str(obj)


def _home_words():
    h = os.path.expanduser("~")
    base = os.path.basename(h.rstrip("/"))
    return [w for w in {h, base} if len(w) >= 3]


def redact(v, n=300):
    """Short text for clients: no absolute paths, no home-directory names."""
    if v is None:
        return None
    s = str(v)
    for w in _home_words():
        s = re.sub(r"(?<!\w)" + re.escape(w) + r"(?!\w)", "<user>", s)
    s = " ".join("<path>" if ("/" in t or "\\" in t) else t for t in s.split())
    s = "".join(c if c.isprintable() else " " for c in s)
    return s[:n]


def _clip(v, n):
    return None if v is None else str(v)[:n]


def public_job(s: dict) -> dict:
    out = s.get("output")
    if isinstance(out, dict):
        out = {"name": redact(os.path.basename(str(out.get("name") or "")), 200), "bytes": out.get("bytes"),
               "type": _clip(out.get("type"), 80)}
    else:
        out = None
    prog = s.get("progress")
    return {"id": _clip(s.get("id"), 64), "kind": _clip(s.get("kind"), 32), "state": _clip(s.get("state"), 32),
            "progress": prog if isinstance(prog, (int, float)) and not isinstance(prog, bool) else None,
            "status": redact(s.get("status"), 200), "error": redact(s.get("error"), 300), "output": out}


class _Bucket:
    def __init__(self, rate, burst, now):
        self.rate, self.burst, self.tokens, self.t = float(rate), float(burst), float(burst), now

    def take(self, now) -> float:
        """0 if allowed, else seconds until a token is available."""
        self.tokens = min(self.burst, self.tokens + (now - self.t) * self.rate)
        self.t = now
        if self.tokens >= 1:
            self.tokens -= 1
            return 0.0
        return (1 - self.tokens) / self.rate if self.rate > 0 else 60.0


# ---------------------------------------------------------------- core (shared by both listeners)

socket_SHUT_RDWR = socket.SHUT_RDWR


class _Core:
    def __init__(self, backend, key_sha256, uploads_dir, outputs_dir, limits, events):
        key_sha256 = str(key_sha256).strip().lower()
        if not re.fullmatch(r"[0-9a-f]{64}", key_sha256):
            raise ValueError("key_sha256 must be 64 hex characters")
        self.backend, self.key_hash, self.limits = backend, key_sha256, limits
        self.events = events or (lambda e: None)
        self.uploads_dir = os.path.abspath(uploads_dir)
        self.outputs_dir = os.path.abspath(outputs_dir)
        os.makedirs(self.uploads_dir, mode=0o700, exist_ok=True)
        os.makedirs(self.outputs_dir, mode=0o700, exist_ok=True)
        self.lock = threading.RLock()
        self.clock = time.monotonic
        self.buckets = {}
        self.bad_auth = {"local": [], "bridge": []}
        self.uploads = {}          # uploadId -> {path, bytes, t, origin}
        self.reserved = 0          # bytes of uploads currently streaming in
        self.devices = []          # [{id, name, token_sha256}]
        self.pairs = {}            # pairId -> dict
        self.pair_times = []
        self.bridge_host = None
        self.last_tick = -1e9
        self.origin_locks = {}
        self.last_seen = {}
        self._purge_orphans()

    # --- logging: method, route, status only; never headers
    def log(self, msg):
        try:
            print("[cns_api] " + msg, file=sys.stderr, flush=True)
        except Exception:
            pass

    def _purge_orphans(self):
        for n in os.listdir(self.uploads_dir):
            if re.fullmatch(r"[0-9a-f-]{36}\.(bin|part)", n):
                try:
                    os.unlink(os.path.join(self.uploads_dir, n))
                except OSError:
                    pass

    # --- auth
    def check_local(self, token: str) -> Optional[str]:
        digest = sha256_hex(token)
        return "api" if hmac.compare_digest(digest, self.key_hash) else None

    def check_device(self, token: str) -> Optional[str]:
        digest = sha256_hex(token)
        found = None
        with self.lock:
            devices = list(self.devices)
        for d in devices:                      # no early exit: time does not depend on which device matched
            if hmac.compare_digest(digest, str(d.get("token_sha256", "")).lower()) and found is None:
                found = d
        if found is None:
            return None
        now = self.clock()
        if now - self.last_seen.get(found["id"], -1e9) > 60:
            self.last_seen[found["id"]] = now
            self.events({"op": "device_seen", "id": found["id"]})
        return "bridge:" + found["id"]

    def note_bad_auth(self, kind) -> bool:
        """Record a failed attempt; True once the per-minute budget is spent (answer 429, still never block a valid key)."""
        now = self.clock()
        with self.lock:
            lst = self.bad_auth[kind]
            lst[:] = [t for t in lst if now - t < 60]
            lst.append(now)
            return len(lst) > self.limits.bad_auth_per_min

    def rate(self, principal: str) -> float:
        L = self.limits
        with self.lock:
            b = self.buckets.get(principal)
            if b is None:
                if principal.startswith("bridge:"):
                    b = _Bucket(L.bridge_rate_per_s, max(2 * L.bridge_rate_per_s, 2), self.clock())
                else:
                    b = _Bucket(L.rate_per_s, L.burst, self.clock())
                self.buckets[principal] = b
            return b.take(self.clock())

    def global_bucket(self, name, rate, burst) -> float:
        with self.lock:
            b = self.buckets.get(name)
            if b is None:
                b = self.buckets[name] = _Bucket(rate, burst, self.clock())
            return b.take(self.clock())

    # --- uploads
    PAIR_GRACE = 300       # seconds an expired / decided pairing stays visible to polling

    def origin_lock(self, origin):
        with self.lock:
            return self.origin_locks.setdefault(origin, threading.Lock())

    def _upload_in_use(self, e):
        for jid, origin in list(e.get("jobs", ())):
            try:
                snap = self.backend.job(jid, origin)
            except Exception:
                snap = None
            if snap and str(snap.get("state", "")).lower() in ACTIVE_STATES:
                return True
        return False

    def sweep(self, force=False):
        now = self.clock()
        with self.lock:
            if not force and now - self.last_tick < 2:
                return
            self.last_tick = now
            expired = [(u, e) for u, e in self.uploads.items() if now - e["t"] > self.limits.upload_ttl]
            for pid in [p for p, e in self.pairs.items() if now - e["t"] > self.limits.pair_ttl + self.PAIR_GRACE]:
                self.pairs.pop(pid, None)
                self.buckets.pop("pair-poll:" + pid, None)
        for uid, e in expired:               # backend is asked outside the lock
            if not self._upload_in_use(e):
                with self.lock:
                    self._drop_upload(uid)

    def _drop_upload(self, uid):
        e = self.uploads.pop(uid, None)
        if e:
            try:
                os.unlink(e["path"])
            except OSError:
                pass

    def reserve(self, n) -> bool:
        with self.lock:
            used = sum(e["bytes"] for e in self.uploads.values()) + self.reserved
            if used + n > self.limits.uploads_total:
                return False
            self.reserved += n
            return True

    def release(self, n):
        with self.lock:
            self.reserved = max(0, self.reserved - n)

    def new_upload(self, origin, nbytes):
        uid = str(uuid.uuid4())
        return uid, os.path.join(self.uploads_dir, uid + ".part"), os.path.join(self.uploads_dir, uid + ".bin")

    def register_upload(self, uid, final, nbytes, origin):
        with self.lock:
            self.uploads[uid] = {"path": final, "bytes": nbytes, "t": self.clock(), "origin": origin, "jobs": []}

    def find_upload(self, uid, origin):
        """Entry for a live upload of this origin; expired ones are not offered to new jobs."""
        if not isinstance(uid, str) or not UPLOAD_ID_RE.match(uid):
            return None
        with self.lock:
            e = self.uploads.get(uid)
            if e is None or e["origin"] != origin:
                return None
            if self.clock() - e["t"] > self.limits.upload_ttl:
                return None                  # the next sweep removes it once no running job uses it
            return e

    def note_upload_job(self, uid, job_id, origin):
        with self.lock:
            e = self.uploads.get(uid)
            if e is not None:
                e["jobs"].append((job_id, origin))

    def clear_uploads(self):
        with self.lock:
            for uid in list(self.uploads):
                self._drop_upload(uid)
        self._purge_orphans()

    # --- pairing
    def pair_start(self, name):
        L, now = self.limits, self.clock()
        with self.lock:
            self.pair_times[:] = [t for t in self.pair_times if now - t < 60]
            if len(self.pair_times) >= L.pair_per_min:
                return None, "rate", 60 - (now - self.pair_times[0])
            pending = [e for e in self.pairs.values() if e["status"] == "pending" and now - e["t"] <= L.pair_ttl]
            if len(pending) >= L.pair_pending:
                return None, "pending", 5
            self.pair_times.append(now)
            pid = secrets.token_urlsafe(16)
            code = "%06d" % secrets.randbelow(10 ** 6)
            self.pairs[pid] = {"name": name, "code": code, "status": "pending", "t": now, "ta": None, "token": None}
        return (pid, code), None, 0

    def pair_exists(self, pid):
        with self.lock:
            return pid in self.pairs

    def pair_state(self, pid):
        now = self.clock()
        with self.lock:
            e = self.pairs.get(pid)
            if e is None:
                return None
            if e["status"] == "pending" and now - e["t"] > self.limits.pair_ttl:
                e["status"] = "expired"
            if e["status"] == "approved" and e["token"] is not None and now - e["ta"] > self.limits.pair_ttl:
                e["token"] = None            # never collected in time: the device must pair again
                e["status"] = "expired"
            if e["status"] == "approved" and e["token"] is not None:
                tok, e["token"] = e["token"], None
                return {"status": "approved", "deviceToken": tok}
            return {"status": e["status"]}

    def decide(self, pid, approve):
        now = self.clock()
        with self.lock:
            e = self.pairs.get(pid)
            if e is None or e["status"] != "pending" or now - e["t"] > self.limits.pair_ttl:
                return
            if not approve:
                e["status"] = "denied"
                return
            tok = secrets.token_urlsafe(32)
            dev = {"id": secrets.token_hex(8), "name": e["name"], "token_sha256": sha256_hex(tok)}
            self.devices.append(dev)
            e["status"], e["token"], e["ta"] = "approved", tok, now
        self.events({"op": "device_added", "id": dev["id"], "name": dev["name"], "token_sha256": dev["token_sha256"]})


# ---------------------------------------------------------------- HTTP

class _Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, addr, handler, core, mode):
        self.core, self.mode = core, mode
        self.slots = threading.BoundedSemaphore(core.limits.connections)
        handler = type("Handler", (handler,), {"timeout": core.limits.socket_timeout})
        super().__init__(addr, handler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(2)
                body = b'{"error":"busy"}'
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                                b"Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nRetry-After: 1\r\n"
                                b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def service_actions(self):
        self.core.sweep()

    def handle_error(self, request, client_address):
        self.core.log("connection error: %s" % sys.exc_info()[0].__name__)

    def allowed_hosts(self):
        if self.mode == "local":
            p = self.server_address[1]
            return ("127.0.0.1:%d" % p, "localhost:%d" % p)
        h = self.core.bridge_host
        return (h, h + ":443") if h else ()


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cns"
    sys_version = ""

    # --- plumbing
    def log_message(self, *a):
        pass

    def send_error(self, code, message=None, explain=None):
        self.close_connection = True
        self._json(code, {"error": (message or "error")[:80]})

    _expect = False

    def handle_one_request(self):
        # total deadline for request line + headers (per-recv timeouts alone let a 1 byte/s sender stay forever)
        timer = threading.Timer(self.server.core.limits.socket_timeout, self._drop_connection)
        timer.daemon = True
        self._hdr_timer = timer
        timer.start()
        try:
            super().handle_one_request()
        finally:
            timer.cancel()

    def _drop_connection(self):
        self.close_connection = True
        try:
            self.connection.shutdown(socket_SHUT_RDWR)
        except OSError:
            pass

    def parse_request(self):
        self._expect = False
        ok = super().parse_request()
        self._hdr_timer.cancel()               # headers are complete: the body has its own deadline
        return ok

    def handle_expect_100(self):
        self._expect = True
        return True

    def _json(self, code, obj, headers=()):
        body = json.dumps(obj, ensure_ascii=True).encode("ascii")
        self._reply(code, body, "application/json", headers)

    def _reply(self, code, body, ctype, headers=(), length=None):
        self.send_response_only(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body) if length is None else length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in headers:
            self.send_header(k, v)
        if getattr(self, "_unread", False) or code in (400, 411, 413, 415, 501):
            self.close_connection = True
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        self.server.core.log("%s %s -> %d" % (self._logmethod(), self._logroute(), code))

    LOG_ROUTES = (
        (re.compile(r"^/v1/jobs/[^/]+/output$"), "/v1/jobs/{id}/output"),
        (re.compile(r"^/v1/jobs/[^/]+/stop$"), "/v1/jobs/{id}/stop"),
        (re.compile(r"^/v1/jobs/[^/]+$"), "/v1/jobs/{id}"),
        (re.compile(r"^/bridge/pair/[^/]+$"), "/bridge/pair/{id}"),
    )
    LOG_FIXED = ("/v1/voices", "/v1/models", "/v1/jobs", "/v1/uploads", "/v1/synthesize", "/v1/clone",
                 "/v1/convert", "/bridge/pair")

    def _logmethod(self):
        m = self.command if isinstance(self.command, str) else ""
        return m if re.fullmatch(r"[A-Z]{1,8}", m) else "?"

    def _logroute(self):
        p = (self.path or "").split("?", 1)[0]
        if p in self.LOG_FIXED:
            return p
        for rx, tpl in self.LOG_ROUTES:
            if rx.match(p):
                return tpl
        return "(other)"            # arbitrary client text is never written to the log

    def _fail(self, code, error, headers=()):
        self._json(code, {"error": error}, headers)

    def _expect_continue(self):
        if getattr(self, "_expect", False):
            self._expect = False
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()

    # --- entry points: every method goes through one gate
    def do_GET(self): self._handle()
    def do_POST(self): self._handle()
    def do_PUT(self): self._handle()
    def do_DELETE(self): self._handle()
    def do_PATCH(self): self._handle()
    def do_OPTIONS(self): self._handle()
    def do_HEAD(self): self._handle()

    def _handle(self):
        try:
            self._route()
        except OSError:                      # client went away or timed out
            self.close_connection = True
        except Exception as e:
            self.server.core.log("internal error: %s" % type(e).__name__)
            self.close_connection = True
            try:
                self._fail(500, "internal")
            except Exception:
                pass

    def _route(self):
        core, srv, L = self.server.core, self.server, self.server.core.limits
        self._unread = False
        has_body = self.command in ("POST", "PUT", "PATCH") or "Content-Length" in self.headers
        te = self.headers.get("Transfer-Encoding")
        self._unread = has_body or te is not None
        # 1. Host (DNS rebinding) and Origin (browsers / CORS) before anything else
        hosts = self.headers.get_all("Host") or []
        if len(hosts) != 1 or hosts[0].strip().lower() not in srv.allowed_hosts():
            return self._fail(403, "forbidden")
        if "Origin" in self.headers:
            return self._fail(403, "forbidden")
        if self.command not in ("GET", "POST"):
            return self._fail(405, "method_not_allowed")
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        is_bridge = srv.mode == "bridge"
        # 2. unauthenticated Bridge pairing routes
        if is_bridge and path == "/bridge/pair" and self.command == "POST":
            return self._pair_post()
        if is_bridge and self.command == "GET" and path.startswith("/bridge/pair/"):
            return self._pair_get(path[len("/bridge/pair/"):])
        # 3. authentication
        auth = self.headers.get_all("Authorization") or []
        token = None
        if len(auth) == 1:
            m = re.fullmatch(r"[Bb]earer ([\x21-\x7e]{1,512})", auth[0].strip())
            token = m.group(1) if m else None
        origin = None
        if token is not None:
            origin = core.check_device(token) if is_bridge else core.check_local(token)
        if origin is None:
            if core.note_bad_auth(srv.mode):
                return self._fail(429, "too_many_attempts", [("Retry-After", "60")])
            return self._fail(401, "unauthorized", [("WWW-Authenticate", "Bearer")])
        wait = core.rate(origin)
        if wait > 0:
            return self._fail(429, "rate_limited", [("Retry-After", str(max(1, int(wait + 0.999))))])
        core.sweep()
        # 4. routing (matched on the raw path: no percent-decoding, so nothing can smuggle separators)
        if self.command == "GET":
            if path == "/v1/voices":
                return self._json(200, {"voices": _scrub(self._catalog().get("voices", []))})
            if path == "/v1/models":
                return self._json(200, {"models": _scrub(self._catalog().get("models", {}))})
            if path == "/v1/jobs":
                jobs = core.backend.jobs(origin) or []
                return self._json(200, {"jobs": [public_job(j) for j in jobs[:100]]})
            m = re.fullmatch(r"/v1/jobs/([^/]+)", path)
            if m:
                return self._job_get(m.group(1), origin)
            m = re.fullmatch(r"/v1/jobs/([^/]+)/output", path)
            if m:
                return self._job_output(m.group(1), origin)
        else:
            if path == "/v1/uploads":
                return self._upload(origin)
            kind = {"/v1/synthesize": "synthesize", "/v1/clone": "clone", "/v1/convert": "convert"}.get(path)
            if kind:
                return self._submit(kind, origin)
            m = re.fullmatch(r"/v1/jobs/([^/]+)/stop", path)
            if m:
                return self._job_stop(m.group(1), origin)
        return self._fail(404, "not_found")

    def _catalog(self):
        c = self.server.core.backend.catalog()
        return c if isinstance(c, dict) else {}

    # --- body handling
    def _content_length(self, limit):
        """Validated Content-Length, or None after having answered."""
        if self.headers.get("Transfer-Encoding") is not None:
            self._fail(501, "chunked_not_supported")
            return None
        cl = self.headers.get_all("Content-Length")
        if not cl:
            self._fail(411, "length_required")
            return None
        if len(cl) != 1 or not re.fullmatch(r"[0-9]{1,12}", cl[0].strip()):
            self._fail(400, "bad_content_length")
            return None
        n = int(cl[0])
        if n > limit:
            self._fail(413, "too_large")
            return None
        return n

    def _read_exact(self, n, sink):
        """Read exactly n bytes.  Every read gets the smaller of the socket timeout and the time left, and the
        whole body must arrive within socket_timeout + n / min_upload_bytes_per_s, so a trickle is dropped."""
        L = self.server.core.limits
        t0 = time.monotonic()
        deadline = t0 + L.socket_timeout + n / float(max(1, L.min_upload_bytes_per_s))
        left = n
        try:
            while left > 0:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.connection.settimeout(max(0.05, min(L.socket_timeout, remaining)))
                chunk = self.rfile.read1(min(65536, left))
                if not chunk:
                    return False
                sink(chunk)
                left -= len(chunk)
        except OSError:
            return False
        finally:
            try:
                self.connection.settimeout(L.socket_timeout)
            except OSError:
                pass
        return True

    def _json_body(self, limit):
        n = self._content_length(limit)
        if n is None:
            return None
        self._expect_continue()
        buf = bytearray()
        if not self._read_exact(n, buf.extend):
            self._fail(400, "incomplete_body")
            return None
        self._unread = False
        try:
            return json.loads(bytes(buf).decode("utf-8"))
        except (ValueError, RecursionError):
            self._fail(400, "invalid_json")
            return None

    # --- routes
    def _upload(self, origin):
        core = self.server.core
        L = core.limits
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if not (ctype.startswith("audio/") or ctype == "application/octet-stream"):
            return self._fail(415, "unsupported_media_type")
        limit = L.bridge_upload if origin.startswith("bridge:") else L.upload
        n = self._content_length(limit)
        if n is None:
            return
        if n == 0:
            return self._fail(400, "empty_upload")
        core.sweep(force=True)
        if not core.reserve(n):
            return self._fail(507, "storage_full")
        uid, part, final = core.new_upload(origin, n)
        fd = None
        try:
            self._expect_continue()
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            f = os.fdopen(fd, "wb")
            fd = None
            with f:
                ok = self._read_exact(n, f.write)
            if not ok:
                os.unlink(part)
                self._fail(400, "incomplete_body")
                return
            self._unread = False
            os.replace(part, final)
            core.register_upload(uid, final, n, origin)
        except BaseException:
            for p in (part, final):
                try:
                    os.unlink(p)
                except OSError:
                    pass
            raise
        finally:
            core.release(n)
            if fd is not None:
                os.close(fd)
        self._json(201, {"uploadId": uid, "bytes": n})

    def _submit(self, kind, origin):
        core = self.server.core
        L = core.limits
        # escaped non-ASCII text is up to 6 bytes per character, so /v1/synthesize gets its own ceiling
        limit = max(L.json_body, L.text_chars * 6 + 4096) if kind == "synthesize" else L.json_body
        data = self._json_body(limit)
        if data is None:
            return
        err = validate(SCHEMAS[kind], data, L)
        if err:
            return self._fail(400, err)
        params = dict(data)
        if kind == "clone" and data.get("consent") is not True:
            return self._fail(400, "consent_required: confirm you have the rights to this voice (consent: true)")
        cat = None
        for fld in ("voice", "model"):
            if fld in data:
                cat = cat or self._catalog()
                if not self._known(cat, "voices" if fld == "voice" else "rvc", data[fld]):
                    return self._fail(404, "unknown_" + fld)
        if kind == "convert" and ("model" in data) == ("voice" in data):
            return self._fail(400, "give exactly one of model or voice")
        if "uploadId" in data:
            up = core.find_upload(data["uploadId"], origin)
            if up is None:
                return self._fail(404, "unknown_upload")
            params["uploadPath"] = up["path"]
        with core.origin_lock(origin):
            active = [j for j in (core.backend.jobs(origin) or [])
                      if str(j.get("state", "")).lower() in ACTIVE_STATES]
            if len(active) >= L.active_jobs:
                return self._fail(429, "too_many_active_jobs", [("Retry-After", "5")])
            job_id, error = core.backend.submit(kind, params, origin)
        if not job_id:
            return self._fail(400, redact(error, 200) or "rejected")
        if "uploadId" in data:
            core.note_upload_job(data["uploadId"], str(job_id)[:64], origin)
        self._json(202, {"jobId": str(job_id)[:64]})

    @staticmethod
    def _known(cat, kind, ident):
        if kind == "voices":
            entries = cat.get("voices", [])
        else:
            entries = (cat.get("models") or {}).get("rvc", [])
        for e in entries:
            if (e if isinstance(e, str) else (e.get("id") if isinstance(e, dict) else None)) == ident:
                return True
        return False

    def _snapshot(self, job_id, origin):
        if not JOB_ID_RE.match(job_id):
            return None
        s = self.server.core.backend.job(job_id, origin)
        return s if isinstance(s, dict) else None

    def _job_get(self, job_id, origin):
        s = self._snapshot(job_id, origin)
        if s is None:
            return self._fail(404, "not_found")
        self._json(200, public_job(s))

    def _job_stop(self, job_id, origin):
        s = self._snapshot(job_id, origin)
        if s is None:
            return self._fail(404, "not_found")
        self.server.core.backend.stop(job_id)
        self._json(202, {"jobId": job_id})

    def _job_output(self, job_id, origin):
        s = self._snapshot(job_id, origin)
        out = s.get("output") if s else None
        if not isinstance(out, dict) or not isinstance(out.get("path"), str):
            return self._fail(404, "not_found")
        root = os.path.realpath(self.server.core.outputs_dir)
        real = os.path.realpath(out["path"])
        if os.path.commonpath([root, real]) != root or real == root:
            self.server.core.log("output outside outputs dir refused")
            return self._fail(404, "not_found")
        try:
            fd = os.open(real, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return self._fail(404, "not_found")
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode):
                return self._fail(404, "not_found")
            name = re.sub(r"[^A-Za-z0-9._-]", "_", str(out.get("name") or os.path.basename(real)))[:100] or "output"
            ctype = out.get("type") if out.get("type") in OUTPUT_TYPES else "application/octet-stream"
            self.send_response_only(200)
            for k, v in (("Content-Type", ctype), ("Content-Length", str(st.st_size)),
                         ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                         ("Content-Disposition", 'attachment; filename="%s"' % name)):
                self.send_header(k, v)
            self.end_headers()
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        self.server.core.log("GET output -> 200")

    # --- Bridge pairing (no authentication; strictly limited)
    def _pair_post(self):
        core = self.server.core
        data = self._json_body(min(core.limits.pair_json_body, core.limits.json_body))
        if data is None:
            return
        err = validate(SCHEMAS["pair"], data, core.limits)
        if err:
            return self._fail(400, err)
        name = sanitize_device_name(data["name"])
        res, why, wait = core.pair_start(name)
        if res is None:
            return self._fail(429, "pairing_" + why, [("Retry-After", str(max(1, int(wait + 0.999))))])
        pid, code = res
        try:
            core.backend.pair_request(pid, name, code)
        except Exception:
            core.log("pair_request failed")
        self._json(201, {"pairId": pid, "code": code})

    def _pair_get(self, pid):
        core = self.server.core
        if not PAIR_ID_RE.match(pid):
            return self._fail(404, "not_found")          # malformed ids cost nothing and charge no bucket
        known = core.pair_exists(pid)
        wait = core.global_bucket("pair-poll:" + pid, 5, 20) if known else core.global_bucket("pair-unknown", 20, 40)
        if wait > 0:
            return self._fail(429, "rate_limited", [("Retry-After", str(max(1, int(wait + 0.999))))])
        st = core.pair_state(pid)
        if st is None:
            return self._fail(404, "not_found")
        self._json(200, st)


# ---------------------------------------------------------------- public server

class ApiServer:
    def __init__(self, backend, key_sha256: str, uploads_dir: str, outputs_dir: str,
                 limits: Limits = Limits(), port: int = 18777, events: Optional[Callable[[dict], None]] = None):
        self.core = _Core(backend, key_sha256, uploads_dir, outputs_dir, limits, events)
        self.port = port
        self._local = None
        self._bridge = None
        self._threads = []

    def _spawn(self, port, mode):
        srv = _Server(("127.0.0.1", port), _Handler, self.core, mode)
        t = threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.1},
                             name="cns-api-" + mode, daemon=True)
        t.start()
        return srv, t

    def start(self) -> int:
        if self._local is not None:
            raise RuntimeError("already started")
        self._local, t = self._spawn(self.port, "local")
        self._threads.append(t)
        return self._local.server_address[1]

    @property
    def local_address(self):
        return self._local.server_address if self._local else None

    @property
    def bridge_address(self):
        return self._bridge.server_address if self._bridge else None

    def start_bridge(self, host: str) -> int:
        host = str(host).strip().lower()
        if not re.fullmatch(r"[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?", host):
            raise ValueError("bad host")
        self.core.bridge_host = host
        if self._bridge is None:
            self._bridge, t = self._spawn(0, "bridge")
            self._threads.append(t)
        return self._bridge.server_address[1]

    def stop_bridge(self) -> None:
        self.core.bridge_host = None
        srv, self._bridge = self._bridge, None
        if srv is not None:
            srv.shutdown()
            srv.server_close()
        with self.core.lock:
            self.core.pairs.clear()

    def set_devices(self, devices: list) -> None:
        """Add / update devices (merge by id).  Removal is only through revoke()."""
        clean = []
        for d in devices or []:
            h = str(d.get("token_sha256", "")).lower()
            if re.fullmatch(r"[0-9a-f]{64}", h) and re.fullmatch(r"[A-Za-z0-9_-]{1,32}", str(d.get("id", ""))):
                clean.append({"id": str(d["id"]), "name": sanitize_device_name(d.get("name", "")), "token_sha256": h})
        with self.core.lock:                  # merge by id: a device approved a moment ago is never dropped
            merged = {d["id"]: d for d in self.core.devices}
            merged.update({d["id"]: d for d in clean})
            self.core.devices = list(merged.values())

    def decide_pair(self, pair_id: str, approve: bool) -> None:
        self.core.decide(pair_id, bool(approve))

    def revoke(self, device_id: str) -> None:
        with self.core.lock:
            self.core.devices = [d for d in self.core.devices if d["id"] != device_id]

    def shutdown(self) -> None:
        for srv in (self._bridge, self._local):
            if srv is not None:
                srv.shutdown()
                srv.server_close()
        self._bridge = self._local = None
        self.core.bridge_host = None
        self.core.clear_uploads()


# ---------------------------------------------------------------- the Bridge tunnel process

class TunnelRunner:
    """Owns the tunnel program (cloudflared) so that it can never outlive this server, and so never the app:
    it runs in its own process group, and is killed when it is asked to stop, when stdin closes (the app is gone),
    when the parent changes (backstop, see watch_parent) and on SIGTERM.  The app names only the verified file;
    the arguments are built here, and the file is hashed again right before it is run."""

    PREFIX = "cloudflared-"

    def __init__(self, emit, bridge_port: Callable[[], Optional[int]]):
        self.emit = emit
        self.bridge_port = bridge_port
        self.lock = threading.Lock()
        self.proc = None

    def start(self, msg) -> None:
        path, sha = str(msg.get("path", "")), str(msg.get("sha256", "")).lower()
        config, home, cwd = str(msg.get("config", "")), str(msg.get("home", "")), str(msg.get("cwd", ""))
        port = self.bridge_port()
        err = None
        try:
            st = os.lstat(path)
            if not (os.path.isabs(path) and os.path.basename(path).startswith(self.PREFIX) and stat.S_ISREG(st.st_mode)
                    and st.st_uid == os.getuid() and not st.st_mode & 0o022 and st.st_mode & 0o100):
                err = "unsafe_file"
            elif not re.fullmatch(r"[0-9a-f]{64}", sha) or _file_sha256(path) != sha:
                err = "hash"
            elif not port:
                err = "no_listener"
            elif not (os.path.isabs(config) and os.path.isabs(home) and os.path.isabs(cwd)):
                err = "bad_args"
        except OSError:
            err = "missing"
        if err:
            self.emit({"op": "tunnel_error", "code": err})
            return
        self.stop()
        args = [path, "tunnel", "--no-autoupdate", "--config", config, "--url", "http://127.0.0.1:%d" % port]
        env = {"HOME": home, "PATH": "/usr/bin:/bin"}
        try:
            proc = subprocess.Popen(args, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
        except OSError:
            self.emit({"op": "tunnel_error", "code": "spawn"})
            return
        with self.lock:
            self.proc = proc
        self.emit({"op": "tunnel_started", "pid": proc.pid})
        threading.Thread(target=self._pump, args=(proc,), daemon=True).start()

    def _pump(self, proc) -> None:
        """Forwards the lines that can hold the public address (and nothing else: the log is never kept)."""
        try:
            for raw in iter(proc.stdout.readline, b""):
                if b"trycloudflare.com" in raw:
                    self.emit({"op": "tunnel_line", "line": raw[:400].decode("utf-8", "replace").rstrip()})
        except (OSError, ValueError):
            pass
        code = proc.wait()
        with self.lock:
            mine = self.proc is proc
            if mine:
                self.proc = None
        if mine:
            self.emit({"op": "tunnel_exit", "code": code})

    def stop(self, grace: float = 1.0) -> None:
        with self.lock:
            proc, self.proc = self.proc, None
        if proc is None or proc.poll() is not None:
            return
        for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 2.0)):
            try:
                os.killpg(proc.pid, sig)
            except OSError:
                return
            end = time.time() + wait
            while time.time() < end and proc.poll() is None:
                time.sleep(0.02)
            if proc.poll() is not None:
                return


def _file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def watch_parent(tunnel: "TunnelRunner", interval: float = 1.0) -> None:
    """Backstop for a parent that vanished without closing stdin: the tunnel goes and so does this process."""
    first = os.getppid()

    def loop():
        while True:
            time.sleep(interval)
            if os.getppid() != first:
                tunnel.stop(grace=0.2)
                os._exit(0)
    threading.Thread(target=loop, daemon=True).start()


# ---------------------------------------------------------------- process entry (stdin / stdout protocol)

class StdioBackend:
    """Backend that talks to the app: requests go out on stdout, state arrives on stdin."""

    def __init__(self, emit):
        self.emit = emit
        self.lock = threading.Lock()
        self.cat = {"voices": [], "models": {"tts": [], "rvc": []}}
        self.snapshots = {}      # jobId -> snapshot (with "origin")
        self.waiting = {}        # reqId -> [Event, result]

    def submit(self, kind, params, origin):
        rid = uuid.uuid4().hex
        ev = threading.Event()
        slot = [ev, (None, "app_unavailable")]
        with self.lock:
            self.waiting[rid] = slot
        self.emit({"op": "submit", "reqId": rid, "kind": kind, "params": params, "origin": origin})
        ev.wait(15)
        with self.lock:
            self.waiting.pop(rid, None)
        if not ev.is_set():
            # the app may still create the job late: it should stop/remove it when it sees this
            self.emit({"op": "submit_abandoned", "reqId": rid})
        return slot[1]

    def resolve(self, msg):
        with self.lock:
            slot = self.waiting.get(msg.get("reqId"))
        if slot:
            slot[1] = (str(msg["jobId"]), None) if msg.get("op") == "submitted" and msg.get("jobId") else \
                (None, str(msg.get("error") or "rejected"))
            slot[0].set()

    def stop(self, job_id):
        self.emit({"op": "stop", "jobId": job_id})

    def update_job(self, snap):
        if not isinstance(snap, dict) or not JOB_ID_RE.match(str(snap.get("id", ""))):
            return
        with self.lock:
            self.snapshots[snap["id"]] = snap
            if len(self.snapshots) > 1000:
                for k in list(self.snapshots)[:200]:
                    self.snapshots.pop(k, None)

    def job(self, job_id, origin_prefix):
        with self.lock:
            s = self.snapshots.get(job_id)
        return s if s and s.get("origin") == origin_prefix else None

    def jobs(self, origin_prefix):
        with self.lock:
            return [s for s in self.snapshots.values() if s.get("origin") == origin_prefix][-100:]

    def set_catalog(self, msg):
        voices, models = msg.get("voices"), msg.get("models")
        with self.lock:
            self.cat = {"voices": voices if isinstance(voices, list) else [],
                        "models": models if isinstance(models, dict) else {"tts": [], "rvc": []}}

    def catalog(self):
        with self.lock:
            return self.cat

    def pair_request(self, pair_id, name, code):
        self.emit({"op": "pair_request", "pairId": pair_id, "name": name, "code": code})


def _limits_from(d) -> Limits:
    base = Limits()
    if isinstance(d, dict):
        ok = {}
        for k, v in d.items():
            if hasattr(base, k) and isinstance(v, (int, float)) and not isinstance(v, bool) \
                    and v == v and 0 < v < 2 ** 40:
                ok[k] = int(v)
        return dataclasses.replace(base, **ok)
    return base


def main() -> None:
    out_lock = threading.Lock()

    def emit(obj):
        with out_lock:
            try:
                sys.stdout.write(json.dumps(obj) + "\n")
                sys.stdout.flush()
            except (OSError, ValueError):
                pass

    backend = StdioBackend(emit)
    state = {"server": None}
    tunnel = TunnelRunner(emit, lambda: (state["server"].bridge_address or (None, None))[1] if state["server"] else None)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))      # the finally below runs: the tunnel goes with us
    signal.signal(signal.SIGHUP, lambda *a: sys.exit(0))
    watch_parent(tunnel)

    def handle(msg):
        """One protocol message.  True means quit."""
        server = state["server"]
        op = msg.get("op")
        if op == "config" and server is None:
            try:
                server = state["server"] = ApiServer(backend, msg["key_sha256"], msg["uploads_dir"], msg["outputs_dir"],
                                   _limits_from(msg.get("limits")), int(msg.get("port", 18777)), events=emit)
                backend.set_catalog(msg)
                server.set_devices(msg.get("devices") or [])
                port = server.start()
                emit({"op": "listening", "port": port, "bridgePort": None})
            except OSError as e:
                state["server"] = None
                emit({"op": "error", "code": "EADDRINUSE" if e.errno == 48 or e.errno == 98 else "OSERROR",
                      "msg": "cannot listen"})
            except (KeyError, ValueError, TypeError):
                state["server"] = None
                emit({"op": "error", "code": "BADCONFIG", "msg": "bad config"})
        elif op == "catalog":
            backend.set_catalog(msg)
        elif op == "job":
            backend.update_job(msg.get("job") if isinstance(msg.get("job"), dict) else msg)
        elif op in ("submitted", "rejected"):
            backend.resolve(msg)
        elif server is not None and op == "pair_decision":
            server.decide_pair(str(msg.get("pairId", "")), bool(msg.get("approve")))
        elif server is not None and op == "bridge":
            try:
                if msg.get("host"):
                    port = server.start_bridge(msg["host"])
                    emit({"op": "listening", "port": server.local_address[1], "bridgePort": port})
                else:
                    tunnel.stop()
                    server.stop_bridge()
                    emit({"op": "listening", "port": server.local_address[1], "bridgePort": None})
            except (OSError, ValueError):
                emit({"op": "error", "code": "BRIDGE", "msg": "cannot start bridge"})
        elif server is not None and op == "tunnel_start":
            tunnel.start(msg)
        elif op == "tunnel_stop":
            tunnel.stop()
        elif server is not None and op == "devices":
            server.set_devices(msg.get("devices") or [])
        elif server is not None and op == "revoke":
            server.revoke(str(msg.get("deviceId", "")))
        elif op == "quit":
            return True
        return False

    try:
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            try:
                if handle(msg):
                    break
            except Exception as e:          # one bad message must never end the loop
                sys.stderr.write("[cns_api] message error: %s\n" % type(e).__name__)
                sys.stderr.flush()
    finally:
        tunnel.stop(grace=0.3)
        if state["server"] is not None:
            state["server"].shutdown()


if __name__ == "__main__":
    main()
