"""Line protocol shared by the pro-engine scripts (stdlib only, Python 3.9+).

A script reads one JSON request from stdin and writes one JSON object per line to
the real stdout: {"event": "status"|"progress"|"log"|"result"|"error", ...}.
Everything else a library prints is sent to stderr by install_stdout_guard().
"""
import json
import os
import sys
import time

_out = None  # the real stdout, kept by install_stdout_guard()

_SYSTEM_PREFIXES = ("/System", "/etc", "/private/etc", "/usr", "/bin", "/sbin",
                    "/private/var/db", "/Library/Keychains", "/dev", "/proc")


class ProtoError(RuntimeError):
    pass


def install_stdout_guard():
    global _out
    if _out is None:
        _out = sys.stdout
    sys.stdout = sys.stderr


def emit(event, **data):
    obj = {"event": event}
    obj.update(data)
    stream = _out if _out is not None else sys.stdout
    stream.write(json.dumps(obj, ensure_ascii=False) + "\n")
    stream.flush()


def status(msg):
    emit("status", message=msg)


def progress(value):
    emit("progress", value=max(0.0, min(1.0, float(value))))


def log(line):
    emit("log", line=str(line))


def result(**data):
    emit("result", **data)


def fail(msg):
    emit("error", message=str(msg))


def read_request():
    raw = sys.stdin.read()
    if not raw.strip():
        raise ProtoError("Bad request: empty")
    try:
        req = json.loads(raw)
    except ValueError as e:
        raise ProtoError("Bad request: %s" % e)
    if not isinstance(req, dict):
        raise ProtoError("Bad request: expected a JSON object")
    return req


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def safe_output_dir(path, roots):
    real = os.path.realpath(os.path.expanduser(str(path)))
    for root in roots:
        if _inside(real, os.path.realpath(root)):
            return real
    raise ProtoError("Output folder is outside the app folders")


def check_input_file(path, max_bytes=4 << 30):
    p = os.path.expanduser(str(path))
    real = os.path.realpath(p)
    if os.path.islink(p) and any(_inside(real, s) for s in _SYSTEM_PREFIXES):
        raise ProtoError("Input file is a link to a system path")
    if not os.path.exists(real):
        raise ProtoError("Input file not found")
    if not os.path.isfile(real):
        raise ProtoError("Input is not a regular file")
    if os.path.getsize(real) > max_bytes:
        raise ProtoError("Input file is too large")
    return real


class ProgressMap:
    """Maps (stage, fraction-in-stage) to a monotonic 0..1 overall value."""

    def __init__(self, stages):
        total = sum(w for _, w in stages) or 1.0
        self._start = {}
        self._weight = {}
        acc = 0.0
        for name, w in stages:
            self._start[name] = acc / total
            self._weight[name] = w / total
            acc += w
        self._last = 0.0

    def at(self, stage, frac):
        if stage not in self._start:
            raise ProtoError("Unknown stage: %s" % stage)
        f = max(0.0, min(1.0, float(frac)))
        v = min(1.0, self._start[stage] + self._weight[stage] * f)
        self._last = max(self._last, v)
        return self._last


class Watchdog:
    """Calls on_stall once when poke() has not been called for timeout_s."""

    def __init__(self, timeout_s, on_stall, clock=time.monotonic):
        self._timeout = timeout_s
        self._on_stall = on_stall
        self._clock = clock
        self._last = clock()
        self._fired = False

    def poke(self):
        self._last = self._clock()

    def check(self):
        if self._fired or self._clock() - self._last < self._timeout:
            return False
        self._fired = True
        self._on_stall()
        return True


def parse_event_line(line):
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    if isinstance(obj, dict) and isinstance(obj.get("event"), str):
        return obj
    return None
