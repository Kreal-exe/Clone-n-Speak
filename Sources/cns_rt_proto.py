"""Block protocol of the realtime voice process (pure: stdlib only, Python 3.9+, no torch, no sockets opened at import).

Frame = magic "CNS1"(4) | type u8 | seq u32 | n u32 | payload (little endian).
  audio (1): n float32 mono samples at 48 kHz (n = block_frame).
  reply (2): proc_ms float32, then n float32 samples (n = 0 means "block dropped"). Replies for dropped blocks are
             sent by the reader as soon as they are dropped, so they can overtake the reply of an earlier block that
             is still being processed: clients must match replies by seq, not by order.
  ctl   (3): n bytes of UTF-8 JSON.
Anything else (bad magic, unknown type, n too large) raises FrameError: the caller closes the connection.
"""
import json
import os
import socket
import stat
import struct

MAGIC = b"CNS1"
T_AUDIO, T_REPLY, T_CTL = 1, 2, 3
HEADER = struct.Struct("<4sBII")
SAMPLE_RATE = 48000
MAX_N = 96000
MAX_CTL = 4096
MAX_QUEUE_BLOCKS = 2

PRESET_LOW_LATENCY = {"block_s": 0.15, "extra_s": 0.1, "crossfade_s": 0.03, "silent_threshold": -60,
                      "f0_method": "rmvpe", "vad_enabled": True, "vad_sensitivity": 2}

# live-control ranges: key -> (lo, hi)
SET_RANGES = {"pitch": (-24, 24), "index_rate": (0.0, 1.0), "protect": (0.0, 0.5), "silent_threshold": (-90.0, 0.0)}


class FrameError(ValueError):
    pass


class PeerClosed(ConnectionError):
    pass


def block_frame(block_s):
    """Samples per block at 48 kHz, a multiple of 480 (10 ms), at least 480 and at most MAX_N."""
    n = int(round(float(block_s) * SAMPLE_RATE / 480.0)) * 480
    return max(480, min(n, (MAX_N // 480) * 480))


def pack_frame(ftype, seq, n, payload=b""):
    return HEADER.pack(MAGIC, ftype, seq & 0xFFFFFFFF, n) + payload


def _raw(samples):
    return bytes(samples) if isinstance(samples, (bytes, bytearray)) else samples.tobytes()


def pack_audio(seq, samples):
    """samples: bytes of float32 LE, or any object with tobytes() (numpy)."""
    raw = _raw(samples)
    return pack_frame(T_AUDIO, seq, len(raw) // 4, raw)


def pack_reply(seq, proc_ms, samples=b""):
    raw = _raw(samples)
    return pack_frame(T_REPLY, seq, len(raw) // 4, struct.pack("<f", float(proc_ms)) + raw)


def pack_ctl(seq, obj):
    raw = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    return pack_frame(T_CTL, seq, len(raw), raw)


def _payload_len(ftype, n):
    if ftype == T_AUDIO:
        return 4 * n
    if ftype == T_REPLY:
        return 4 + 4 * n
    return n


class FrameDecoder:
    """Incremental decoder: feed() takes whatever recv() returned (any split, several frames at once) and returns the
    complete frames as (type, seq, n, payload). The header is validated as soon as it is complete, so garbage never
    makes the decoder wait for (or buffer) a huge payload."""

    def __init__(self):
        self._buf = bytearray()

    def feed(self, data):
        self._buf += data
        out = []
        while len(self._buf) >= HEADER.size:
            magic, ftype, seq, n = HEADER.unpack_from(self._buf)
            if magic != MAGIC:
                raise FrameError("bad magic")
            if ftype not in (T_AUDIO, T_REPLY, T_CTL):
                raise FrameError("unknown frame type %d" % ftype)
            if ftype == T_CTL:
                if n > MAX_CTL:
                    raise FrameError("control frame too large")
            elif n > MAX_N:
                raise FrameError("frame too large")
            end = HEADER.size + _payload_len(ftype, n)
            if len(self._buf) < end:
                break
            out.append((ftype, seq, n, bytes(self._buf[HEADER.size:end])))
            del self._buf[:end]
        return out

    @property
    def pending(self):
        return len(self._buf)


def read_frames(sock, decoder, bufsize=65536):
    """Blocking recv -> list of complete frames (maybe empty). A closed or reset peer raises PeerClosed;
    FrameError propagates; a socket timeout propagates as socket.timeout."""
    try:
        data = sock.recv(bufsize)
    except socket.timeout:
        raise
    except OSError as e:
        raise PeerClosed(str(e))
    if not data:
        raise PeerClosed("peer closed")
    return decoder.feed(data)


def send_all(sock, data):
    try:
        sock.sendall(data)
    except OSError as e:
        raise PeerClosed(str(e))


def decode_reply(payload):
    return struct.unpack_from("<f", payload)[0], payload[4:]


class DropQueue:
    """Input blocks waiting for the model. Holds at most `limit` blocks: when full, the OLDEST are dropped so the newest
    audio is what gets converted. push() returns the seqs it dropped (the caller answers each with a reply n=0)."""

    def __init__(self, limit=MAX_QUEUE_BLOCKS):
        self.limit = limit
        self._items = []
        self.dropped = 0

    def push(self, seq, data):
        self._items.append((seq, data))
        dropped = []
        while len(self._items) > self.limit:
            dropped.append(self._items.pop(0)[0])
        self.dropped += len(dropped)
        return dropped

    def pop(self):
        return self._items.pop(0) if self._items else None

    def __len__(self):
        return len(self._items)


class LatencyStats:
    def __init__(self):
        self._ms = []
        self.dropped = 0

    def add(self, ms):
        self._ms.append(float(ms))

    @staticmethod
    def _pct(sorted_vals, q):
        if not sorted_vals:
            return 0.0
        k = -(-q * len(sorted_vals) // 100)   # nearest rank, ceil
        return sorted_vals[max(0, min(len(sorted_vals) - 1, int(k) - 1))]

    def summary(self):
        s = sorted(self._ms)
        return {"blocks": len(s), "p50_ms": round(self._pct(s, 50), 1), "p95_ms": round(self._pct(s, 95), 1),
                "dropped": self.dropped}


def validate_set(cmd):
    """{"set": {...}} -> clean dict of known keys, numbers inside SET_RANGES. Raises ValueError with the reason."""
    body = cmd.get("set") if isinstance(cmd, dict) else None
    if not isinstance(body, dict) or not body:
        raise ValueError("set needs an object")
    out = {}
    for k, v in body.items():
        if k not in SET_RANGES:
            raise ValueError("unknown setting %s" % k)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
            raise ValueError("%s must be a number" % k)
        lo, hi = SET_RANGES[k]
        if not lo <= v <= hi:
            raise ValueError("%s must be between %s and %s" % (k, lo, hi))
        out[k] = v
    return out


def parse_control_line(line):
    """A stdin line -> ("set", dict) | ("quit", None). Raises ValueError for garbage."""
    try:
        obj = json.loads(line)
    except (ValueError, TypeError, RecursionError):
        raise ValueError("not JSON")
    if not isinstance(obj, dict):
        raise ValueError("expected an object")
    if obj.get("cmd") == "quit":
        return "quit", None
    if "set" in obj:
        return "set", validate_set(obj)
    raise ValueError("unknown command")


def quit_result(stats):
    """The data of the final result event."""
    return {"stats": stats.summary() if hasattr(stats, "summary") else dict(stats)}


def listen_unix(path, backlog=1):
    """Binds a Unix socket at `path`: parent directory 0700, socket 0600 (umask during bind, chmod after). A stale
    socket of ours at the path is replaced. The bind happens from inside the parent directory with the short file name,
    so paths longer than the 104-byte AF_UNIX limit work (cwd is restored; clients must do the same). Raises OSError
    with a readable message when it still cannot bind. Returns the listening socket."""
    path = os.path.abspath(path)
    parent, name = os.path.split(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    st = os.lstat(parent)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise OSError("Realtime socket folder is not yours: %s" % parent)
    os.chmod(parent, 0o700)
    if len(os.fsencode(name)) > 100:
        raise OSError("Realtime socket name is too long")
    try:
        old_st = os.lstat(path)
    except FileNotFoundError:
        old_st = None
    if old_st is not None:
        if not stat.S_ISSOCK(old_st.st_mode) or old_st.st_uid != os.getuid():
            raise OSError("Something else is at the realtime socket path: %s" % path)
        os.unlink(path)
    cwd = os.getcwd()
    old = os.umask(0o177)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.chdir(parent)
        s.bind(name)
        os.chmod(name, 0o600)
        s.listen(backlog)
    except OSError as e:
        s.close()
        raise OSError("Could not open the realtime socket (%s)" % e)
    finally:
        os.umask(old)
        os.chdir(cwd)
    return s


def connect_unix(path):
    """Client side of listen_unix: connects through the parent directory so long paths work."""
    path = os.path.abspath(path)
    parent, name = os.path.split(path)
    cwd = os.getcwd()
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.chdir(parent)
        c.connect(name)
    except OSError:
        c.close()
        raise
    finally:
        os.chdir(cwd)
    return c
