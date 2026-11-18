"""Line protocol shared by the pro-engine scripts (stdlib only, Python 3.9+).

A script reads one JSON request from stdin and writes one JSON object per line to
the real stdout: {"event": "status"|"progress"|"log"|"result"|"error", ...}.
Everything else a library prints is sent to stderr by install_stdout_guard().
"""
import json
import math
import os
import sys
import threading
import time

_out = None  # the real protocol channel, kept by install_stdout_guard()
_lock = threading.Lock()

_FORBIDDEN = ("/System", "/etc", "/private/etc", "/usr", "/bin", "/sbin",
              "/private/var/db", "/Library/Keychains", "/dev", "/proc")


class ProtoError(RuntimeError):
    pass


def install_stdout_guard():
    """Keep a private dup of fd 1 for events; fd 1 and sys.stdout then point at stderr, so
    prints, os.write(1, ...), sys.__stdout__ and child processes cannot reach the channel."""
    global _out
    if _out is not None:
        return
    _out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr


def _default(o):
    try:
        f = float(o)
    except (TypeError, ValueError, OverflowError):
        return str(o)
    if f.is_integer() and not isinstance(o, float):
        return int(f)
    return f


def _clean(o):
    if isinstance(o, float):
        return o if math.isfinite(o) else None
    if isinstance(o, dict):
        return {str(k): _clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_clean(v) for v in o]
    if o is None or isinstance(o, (str, int, bool)):
        return o
    d = _default(o)
    return d if isinstance(d, str) else _clean(d)


def emit(event, **data):
    obj = {"event": event}
    obj.update(data)
    line = json.dumps(_clean(obj), ensure_ascii=False, allow_nan=False)
    with _lock:
        stream = _out if _out is not None else sys.stdout
        stream.write(line + "\n")
        stream.flush()


def status(msg):
    emit("status", msg=str(msg))


def progress(value):
    emit("progress", value=max(0.0, min(1.0, float(value))))


def log(line):
    emit("log", line=str(line))


def partial(path):
    emit("partial", path=str(path))


def result(**data):
    emit("result", data=data)


def fail(msg):
    emit("error", msg=str(msg))


def read_request():
    """Reads exactly ONE line of stdin (the request); later lines stay in sys.stdin for the
    caller (realtime reads live {"set":...}/{"cmd":"quit"} lines from the same pipe)."""
    try:
        raw = sys.stdin.readline()
    except UnicodeDecodeError as e:
        raise ProtoError("Bad request: %s" % e)
    if not raw.strip():
        raise ProtoError("Bad request: empty")
    try:
        req = json.loads(raw)
    except (ValueError, RecursionError) as e:
        raise ProtoError("Bad request: %s" % e)
    if not isinstance(req, dict):
        raise ProtoError("Bad request: expected a JSON object")
    return req


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def safe_output_dir(path, roots):
    if not str(path).strip():
        raise ProtoError("Output folder is outside the app folders")
    real = os.path.realpath(os.path.expanduser(str(path)))
    for root in roots:
        if _inside(real, os.path.realpath(root)):
            return real
    raise ProtoError("Output folder is outside the app folders")


def check_input_file(path, max_bytes=4 << 30):
    """Returns the realpath (callers open it). Rejects system/secret locations by the
    resolved path, whatever symlinks lead there."""
    real = os.path.realpath(os.path.expanduser(str(path)))
    home = os.path.realpath(os.path.expanduser("~"))
    forbidden = _FORBIDDEN + (home + "/.ssh", home + "/Library/Keychains")
    if any(_inside(real, os.path.realpath(r)) for r in forbidden):
        raise ProtoError("Input file is in a protected location")
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

    @property
    def value(self):
        """The last value returned by at() (0 before the first call)."""
        return self._last

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
