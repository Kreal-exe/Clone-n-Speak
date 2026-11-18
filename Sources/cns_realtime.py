"""Realtime voice conversion process (pro engine): Applio rvc.realtime.core.VoiceChanger behind a Unix socket.

    <pro python> -s cns_realtime.py run      (cwd = Applio root; request JSON on stdin, then live control lines)

Request: model (folder with .pth and optional .index), socket (inside work_dir), work_dir, block_s, extra_s,
crossfade_s, silent_threshold, vad{on,sensitivity}, f0_method, pitch, index_rate, protect.
stdin after the request: {"set":{"pitch","index_rate","protect","silent_threshold"}} and {"cmd":"quit"}.
Audio goes over the socket (cns_rt_proto): one client, 48 kHz mono float32 blocks, replies in order. The app holds the
microphone. Needs the GPU (MPS): on this Mac the CPU needs 533 ms per 0.25 s block, so it never starts there.
"""
import os
import select
import socket
import sys
import threading
import time

import cns_proto
import cns_rt_proto as rt

NO_GPU_MSG = "Realtime needs the GPU (MPS) — on this Mac it would be too slow"
MODEL_MSG = "Voice model not found. Pick a voice in Models and try again."
ACCEPT_TIMEOUT_S = 300.0


def find_model_files(model_dir):
    """(pth, index|None) inside a model folder, or raises ProtoError."""
    if not model_dir or not os.path.isdir(model_dir):
        raise cns_proto.ProtoError(MODEL_MSG)
    names = sorted(os.listdir(model_dir))
    pths = [n for n in names if n.endswith(".pth")]
    if not pths:
        raise cns_proto.ProtoError(MODEL_MSG)
    idx = [n for n in names if n.endswith(".index")]
    return os.path.join(model_dir, pths[0]), (os.path.join(model_dir, idx[0]) if idx else None)


def settings_from_request(req):
    """Merges the request over the Low-latency preset; block size is snapped to 480-sample steps."""
    s = dict(rt.PRESET_LOW_LATENCY)
    for k in ("block_s", "extra_s", "crossfade_s", "silent_threshold", "f0_method"):
        if req.get(k) is not None:
            s[k] = req[k]
    vad = req.get("vad") or {}
    if "on" in vad:
        s["vad_enabled"] = bool(vad["on"])
    if vad.get("sensitivity") is not None:
        s["vad_sensitivity"] = max(0, min(3, int(vad["sensitivity"])))
    for k, (lo, hi) in {"block_s": (0.02, 1.9), "extra_s": (0.0, 2.0), "crossfade_s": (0.0, 0.5)}.items():
        v = s[k]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
            raise cns_proto.ProtoError("Bad parameter: %s must be a number between %s and %s" % (k, lo, hi))
    s["block_frame"] = rt.block_frame(s["block_s"])
    s["live"] = {"pitch": req.get("pitch", 0), "index_rate": req.get("index_rate", 0.3),
                 "protect": req.get("protect", 0.33), "silent_threshold": s["silent_threshold"]}
    rt.validate_set({"set": s["live"]})
    return s


class VadGate:
    """webrtcvad over a 48 kHz block: True when any 10 ms frame (decimated to 16 kHz) holds speech."""

    def __init__(self, sensitivity):
        import webrtcvad
        self._vad = webrtcvad.Vad(sensitivity)

    def has_speech(self, block):
        import numpy as np
        x = np.asarray(block, dtype=np.float32)
        n = (len(x) // 3) * 3
        y = x[:n].reshape(-1, 3).mean(axis=1)
        pcm = (np.clip(y, -1.0, 1.0) * 32767).astype("<i2").tobytes()
        step = 320 * 2   # 20 ms at 16 kHz
        for i in range(0, len(pcm) - step + 1, step):
            if self._vad.is_speech(pcm[i:i + step], 16000):
                return True
        return False


class Hangover:
    """Decides which blocks go through the model. A block is skipped only after `hang` consecutive blocks without
    speech, so short pauses (and the tail of a word) still run through the model."""

    def __init__(self, vad, hang=2):
        self.vad, self.hang, self._left = vad, hang, 0

    def process(self, block):
        if self.vad is None or self.vad.has_speech(block):
            self._left = self.hang
            return True
        if self._left > 0:
            self._left -= 1
            return True
        return False


FADE_S = 0.005
_warned_resample = False


def fade(block, tail=None, fade_in=False, rate=rt.SAMPLE_RATE):
    """Short linear ramps instead of hard cuts: fade_in ramps a block up from 0; `tail` (the last output sample) decays
    to 0 over the start of a silent block."""
    import numpy as np
    m = min(len(block), max(1, int(FADE_S * rate)))
    block = np.array(block, dtype=np.float32)
    if fade_in:
        block[:m] *= np.linspace(0.0, 1.0, m, dtype=np.float32)
    if tail is not None:
        block[:m] += np.float32(tail) * np.linspace(1.0, 0.0, m, dtype=np.float32)
    return block


def fit(out, n):
    """Model output -> exactly n float32 samples (trim, zero-pad, or linear-resample if the rate differs)."""
    import numpy as np
    out = np.asarray(out, dtype=np.float32).reshape(-1)
    if len(out) == n:
        return out
    if abs(len(out) - n) > max(1, n // 50):
        global _warned_resample
        if not _warned_resample:
            _warned_resample = True
            cns_proto.log("model output has %d samples, resampling to %d" % (len(out), n))
        return np.interp(np.linspace(0, len(out) - 1, n), np.arange(len(out)), out).astype(np.float32)
    if len(out) > n:
        return out[:n]
    return np.concatenate([out, np.zeros(n - len(out), dtype=np.float32)])


class Session:
    def __init__(self, vc, settings):
        self.vc, self.s, self.conn = vc, settings, None
        self.live = dict(settings["live"])
        self.lock = threading.Lock()
        self.send_lock = threading.Lock()
        self.cv = threading.Condition()
        self.queue = rt.DropQueue()
        self.stats = rt.LatencyStats()
        self.stop = threading.Event()
        self.gate = None
        self.error = None
        self._last_out = 0.0
        self._was_gated = False
        if settings["vad_enabled"]:
            try:
                self.gate = Hangover(VadGate(settings["vad_sensitivity"]))
            except Exception as e:  # noqa: BLE001 — VAD is optional; the silence threshold still gates
                cns_proto.log("VAD unavailable (%s); using the silence threshold only" % e)

    def send(self, data):
        with self.send_lock:
            rt.send_all(self.conn, data)

    def apply(self, changes):
        with self.lock:
            self.live.update(changes)
        if "silent_threshold" in changes:
            try:
                self.vc.silent_threshold = changes["silent_threshold"]
            except Exception:  # noqa: BLE001
                pass

    def reader(self):
        dec = rt.FrameDecoder()
        try:
            while not self.stop.is_set():
                if not select.select([self.conn], [], [], 0.5)[0]:
                    continue   # idle gap: the connection stays open until the client leaves
                for ftype, seq, n, payload in rt.read_frames(self.conn, dec):
                    if ftype != rt.T_AUDIO:
                        continue
                    if n != self.s["block_frame"]:
                        raise rt.FrameError("block of %d samples, expected %d" % (n, self.s["block_frame"]))
                    with self.cv:
                        dropped = self.queue.push(seq, payload)
                        self.stats.dropped = self.queue.dropped
                        self.cv.notify()
                    for d in dropped:
                        self.send(rt.pack_reply(d, 0.0))
        except (rt.PeerClosed, rt.FrameError, OSError) as e:
            cns_proto.log("client ended: %s" % e)
        finally:
            self.stop.set()
            with self.cv:
                self.cv.notify_all()

    def worker(self):
        import numpy as np
        try:
            while True:
                with self.cv:
                    while not len(self.queue) and not self.stop.is_set():
                        self.cv.wait(0.2)
                    item = self.queue.pop()
                if item is None:
                    return
                seq, payload = item
                block = np.frombuffer(payload, dtype="<f4")
                t0 = time.perf_counter()
                if self.gate is not None and not self.gate.process(block):
                    out = np.zeros(len(block), dtype=np.float32)
                    if not self._was_gated:
                        out = fade(out, tail=self._last_out)
                    self._was_gated = True
                    self.send(rt.pack_reply(seq, 0.0, out.astype("<f4")))   # gated: not counted in the latency stats
                    continue
                else:
                    with self.lock:
                        live = dict(self.live)
                    res = self.vc.on_request(block.astype(np.float32), f0_up_key=live["pitch"],
                                             index_rate=live["index_rate"], protect=live["protect"])
                    out = fit(res[0] if isinstance(res, (tuple, list)) else res, len(block))
                    if self._was_gated:
                        out = fade(out, fade_in=True)
                    self._was_gated = False
                    self._last_out = float(out[-1]) if len(out) else 0.0
                ms = (time.perf_counter() - t0) * 1000.0
                self.stats.add(ms)
                self.send(rt.pack_reply(seq, ms, out.astype("<f4")))
        except (rt.PeerClosed, OSError):
            pass
        except Exception as e:  # noqa: BLE001 — a model failure must not look like a normal end
            self.error = "Realtime stopped: %s" % e
        finally:
            self.stop.set()

    def control(self, stream):
        """stdin lines after the request; EOF means the app is gone."""
        for line in stream:
            if not line.strip():
                continue
            try:
                kind, body = rt.parse_control_line(line)
            except ValueError as e:
                cns_proto.log("ignored control line: %s" % e)
                continue
            if kind == "quit":
                break
            self.apply(body)
        self.stop.set()
        with self.cv:
            self.cv.notify_all()


def _load_voice_changer(settings, pth, index):
    import torch
    if not torch.backends.mps.is_available():
        raise cns_proto.ProtoError(NO_GPU_MSG)
    applio = settings.get("applio_dir")
    if applio:
        os.chdir(applio)      # Applio resolves its assets relative to its own root
        if applio not in sys.path:
            sys.path.insert(0, applio)
    from rvc.realtime.core import VoiceChanger
    return VoiceChanger(block_frame=settings["block_frame"], cross_fade_overlap_size=settings["crossfade_s"],
                        extra_convert_size=settings["extra_s"], model_path=pth, index_path=index,
                        f0_method=settings["f0_method"], embedder_model="contentvec",
                        silent_threshold=settings["silent_threshold"], device="mps")


def run(req, stdin=None, loader=None):
    """Loads and warms the model, prints status "ready", serves one client until it leaves or {"cmd":"quit"}.
    `loader` is a seam for tests (returns an object with warmup/on_request)."""
    stdin = stdin if stdin is not None else sys.stdin
    settings = settings_from_request(req)
    if req.get("root"):
        import cns_engines
        settings["applio_dir"] = cns_engines.applio_dir(os.path.abspath(req["root"]))
    pth, index = find_model_files(req.get("model"))
    work = os.path.realpath(req.get("work_dir") or "")
    sock_path = req.get("socket") or ""
    sock_dir = os.path.realpath(os.path.dirname(os.path.abspath(sock_path)))
    if not work or os.path.commonpath([work, sock_dir]) != work:
        raise cns_proto.ProtoError("Realtime socket must be inside the job folder")
    cns_proto.status("Loading the voice model")
    vc = (loader or _load_voice_changer)(settings, pth, index)
    cns_proto.status("Warming up")
    vc.warmup(index_rate=settings["live"]["index_rate"], protect=settings["live"]["protect"])
    srv = rt.listen_unix(sock_path)
    try:
        cns_proto.status("ready")
        srv.settimeout(0.5)
        sess = Session(vc, settings)
        threading.Thread(target=sess.control, args=(stdin,), daemon=True).start()   # a quit may come before any client
        deadline = time.monotonic() + ACCEPT_TIMEOUT_S
        while sess.conn is None and not sess.stop.is_set():
            if time.monotonic() > deadline:
                raise cns_proto.ProtoError("No client connected to the realtime socket")
            try:
                sess.conn, _ = srv.accept()
            except socket.timeout:
                continue
        if sess.conn is not None:
            srv.close()
            t_rd = threading.Thread(target=sess.reader, daemon=True)
            t_wk = threading.Thread(target=sess.worker, daemon=True)
            t_rd.start()
            t_wk.start()
            sess.stop.wait()
            t_wk.join(2.0)
            t_rd.join(2.0)
            try:
                sess.conn.close()
            except OSError:
                pass
        if sess.error:
            raise cns_proto.ProtoError(sess.error)
        cns_proto.result(**rt.quit_result(sess.stats))
    finally:
        try:
            srv.close()
        except OSError:
            pass
        try:
            os.unlink(sock_path)
        except OSError:
            pass


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cns_proto.install_stdout_guard()
    if argv[:1] != ["run"]:
        cns_proto.fail("usage: cns_realtime.py run")
        return 2
    try:
        run(cns_proto.read_request())
        return 0
    except cns_proto.ProtoError as e:
        cns_proto.fail(str(e))
        return 1
    except Exception as e:  # noqa: BLE001
        cns_proto.fail("Realtime failed: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
