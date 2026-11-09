"""Shared foundation of the light audio features (Clone'n'Speak 2.0).

worker.py imports this module; every Sources/cns_<name>.py module imports it too and plugs in through
COMMANDS (new worker commands), register_effect (effect chain), TOOLS (test registry) and the POST_SYNTH /
PRE_ENHANCE hooks. Only the standard library is imported at module level: numpy and scipy are loaded inside the
functions, so importing this file is cheap and safe without them. Python 3.9 compatible.

Nothing here ever prints to stdout (it is the worker's protocol channel); events go through emit_status /
emit_progress, which worker.py binds with bind().
"""
import importlib.util
import os
import sys

SR = 24000
MAX_SECONDS = 1200  # 20 minutes: the limit of every file tool


class AudioInputError(ValueError):
    """An input the tools cannot work with. `code` is one of empty, too_short, silent, unsupported, too_long,
    bad_param; `message` names the action to take and is what the user sees (str(e) == message)."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# Events (bound by worker.py)
# --------------------------------------------------------------------------
_emit = None
_status = None
_free = None


def bind(emit=None, status=None, free=None):
    """worker.py hands over its protocol functions: emit(event, **data), status(msg), free()."""
    global _emit, _status, _free
    _emit, _status, _free = emit, status, free


def emit_status(msg):
    if _status is not None:
        _status(msg)
    else:
        print(msg, file=sys.stderr, flush=True)


def emit_progress(v):
    if _emit is not None:
        _emit("progress", value=float(v))


def free_models():
    """Unloads the speech models before a heavy tool runs (keeps the peak memory of the main scenario)."""
    if _free is not None:
        _free()


# --------------------------------------------------------------------------
# Reading and writing
# --------------------------------------------------------------------------
def _fail(code, message):
    raise AudioInputError(code, message)


def _limit_text(max_seconds):
    m = max_seconds / 60.0
    return ("%d" % m) if m == int(m) else ("%.1f" % m)


class _Unreadable(Exception):
    pass


def _wav_header(path):
    """(rate, frames) from the RIFF header without decoding the samples, or None when it cannot be told."""
    import struct
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(12)
            if head[:4] not in (b"RIFF", b"RF64") or head[8:12] != b"WAVE":
                return None
            rate = align = None
            while True:
                chunk = f.read(8)
                if len(chunk) < 8:
                    return None
                cid, csize = chunk[:4], struct.unpack("<I", chunk[4:])[0]
                if cid == b"fmt ":
                    fmt = f.read(csize)
                    rate, align = struct.unpack("<I", fmt[4:8])[0], struct.unpack("<H", fmt[12:14])[0]
                    f.seek(csize & 1, 1)
                elif cid == b"data":
                    if csize == 0xFFFFFFFF or f.tell() + csize > size:
                        csize = size - f.tell()
                    if not rate or not align:
                        return None
                    return rate, csize // align
                else:
                    f.seek(csize + (csize & 1), 1)
    except (OSError, struct.error):
        return None


def _read_wav(path):
    import numpy as np
    from scipy.io import wavfile
    try:
        sr, data = wavfile.read(path)
    except Exception:
        raise _Unreadable()
    data = np.asarray(data)
    if data.dtype == np.uint8:
        x = (data.astype(np.float32) - 128.0) / 128.0
    elif data.dtype == np.int16:
        x = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        x = (data.astype(np.float64) / 2147483648.0).astype(np.float32)
    elif data.dtype in (np.float32, np.float64):
        x = np.nan_to_num(data.astype(np.float32), nan=0.0, posinf=1.0, neginf=-1.0)
    else:
        raise _Unreadable()
    return x, int(sr)


def _read_other(path):
    try:
        from mlx_audio.audio_io import read as audio_read
    except Exception:
        _fail("unsupported", "Convert it to WAV first (Audio Tools → Convert).")
    try:
        data, sr = audio_read(str(path), dtype="float32", always_2d=False)
    except Exception:
        _fail("unsupported", "This file could not be decoded. Convert it to WAV first (Audio Tools → Convert).")
    import numpy as np
    data = np.asarray(data, dtype=np.float32)
    if data.ndim == 2 and data.shape[0] < data.shape[1] and data.shape[0] <= 8:
        data = data.T  # channels-first decoders
    return data, int(sr)


def resample(wav, sr_from, sr_to):
    """Polyphase resampling along the time axis (axis 0) of any shape."""
    import numpy as np
    wav = np.asarray(wav)
    sr_from, sr_to = int(sr_from), int(sr_to)
    if sr_from == sr_to or wav.shape[0] == 0:
        return wav.astype(np.float32, copy=False)
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(sr_from, sr_to)
    return resample_poly(wav, sr_to // g, sr_from // g, axis=0).astype(np.float32)


def read_audio(path, *, sr=None, mono=True, min_seconds=0.0, max_seconds=MAX_SECONDS, allow_silent=True):
    """Reads an audio file as float32 in [-1, 1]: shape (n,) when mono, else (n, channels). Returns (wav, rate).
    `sr` resamples. Raises AudioInputError(code, message) for anything the tools cannot work with."""
    import numpy as np
    path = str(path)
    try:
        size = os.path.getsize(path)
    except OSError:
        _fail("empty", "The file could not be opened. Choose an existing audio file.")
    if size == 0:
        _fail("empty", "The file is empty. Choose a recording that has sound in it.")
    with open(path, "rb") as f:
        head = f.read(12)
    is_wav = path.lower().endswith(".wav") or (head[:4] in (b"RIFF", b"RF64") and head[8:12] == b"WAVE")
    if is_wav and max_seconds:  # refuse a huge file from its header, before decoding it
        header = _wav_header(path)
        if header and header[0] > 0 and header[1] / float(header[0]) > max_seconds:
            _fail("too_long", "The audio is %.0f minutes long. Cut it first: the limit is %s minutes."
                              % (header[1] / float(header[0]) / 60.0, _limit_text(max_seconds)))
    if is_wav:
        try:
            wav, rate = _read_wav(path)
        except _Unreadable:
            wav, rate = _read_other(path)  # a WAV flavour scipy cannot read may still decode elsewhere
    else:
        wav, rate = _read_other(path)
    if wav.ndim == 2 and wav.shape[1] == 1:
        wav = wav[:, 0]
    if wav.ndim != 2 and wav.ndim != 1:
        _fail("unsupported", "This audio layout is not supported. Convert it to WAV first (Audio Tools → Convert).")
    n = wav.shape[0]
    if n == 0 or rate <= 0:
        _fail("empty", "The file has no audio in it. Choose a recording that has sound in it.")
    seconds = n / float(rate)
    if max_seconds and seconds > max_seconds:
        _fail("too_long", "The audio is %.0f minutes long. Cut it first: the limit is %s minutes."
                          % (seconds / 60.0, _limit_text(max_seconds)))
    if seconds < min_seconds:
        _fail("too_short", "The audio is only %.1f seconds long. Use a recording of at least %.1f seconds."
                           % (seconds, min_seconds))
    if not allow_silent and float(np.abs(wav).max()) < 1e-4:
        _fail("silent", "The audio is silent. Choose a recording that has sound in it.")
    if mono and wav.ndim == 2:
        wav = wav.mean(axis=1)
    wav = np.ascontiguousarray(wav, dtype=np.float32)
    if sr is not None and int(sr) != rate:
        wav = resample(wav, rate, int(sr))
        rate = int(sr)
    return wav, rate


def write_audio(path, wav, sr, *, subtype="pcm16"):
    """Writes a mono (n,) or stereo (n, 2) WAV atomically (.part, then os.replace). Returns the seconds written."""
    import numpy as np
    path = str(path)
    x = np.asarray(wav, dtype=np.float32)
    if x.ndim == 2 and x.shape[1] == 1:
        x = x[:, 0]
    if x.ndim not in (1, 2) or (x.ndim == 2 and x.shape[1] > 8):
        raise ValueError("Unexpected audio shape: %s" % (x.shape,))
    x = np.nan_to_num(x, nan=0.0, posinf=1.0, neginf=-1.0)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".part"
    try:
        if subtype == "float32":
            from scipy.io import wavfile
            with open(tmp, "wb") as f:
                wavfile.write(f, int(sr), x)
        elif subtype in ("pcm16", "pcm24"):
            import wave
            ch = 1 if x.ndim == 1 else x.shape[1]
            clipped = np.clip(x, -1.0, 1.0)
            if subtype == "pcm16":
                raw = (clipped * 32767.0).round().astype("<i2").tobytes()
                width = 2
            else:
                ints = (clipped.astype(np.float64) * 8388607.0).round().astype("<i4")
                raw = ints.reshape(-1).view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
                width = 3
            with wave.open(tmp, "wb") as wf:
                wf.setnchannels(ch)
                wf.setsampwidth(width)
                wf.setframerate(int(sr))
                wf.writeframes(raw)
        else:
            raise ValueError("Unknown WAV subtype: %s" % subtype)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return x.shape[0] / float(sr)


def map_channels(wav, fn):
    """Applies fn to a mono signal, or to every channel of an (n, ch) signal."""
    import numpy as np
    wav = np.asarray(wav)
    if wav.ndim == 1:
        return fn(wav)
    return np.stack([fn(np.ascontiguousarray(wav[:, c])) for c in range(wav.shape[1])], axis=1)


# --------------------------------------------------------------------------
# DSP moved from worker.py (unchanged)
# --------------------------------------------------------------------------
def biquad(kind, freq, gain_db, sr=SR, q=0.707):
    """RBJ cookbook low shelf / high shelf / peak as one second-order section."""
    import numpy as np
    A = 10 ** (gain_db / 40.0)
    w = 2 * np.pi * freq / sr
    cw, alpha = np.cos(w), np.sin(w) / (2 * q)
    if kind == "peak":
        b = [1 + alpha * A, -2 * cw, 1 - alpha * A]
        a = [1 + alpha / A, -2 * cw, 1 - alpha / A]
    else:
        k = 2 * np.sqrt(A) * alpha
        sign = 1 if kind == "low" else -1  # the two shelves mirror each other
        b = [A * ((A + 1) - sign * (A - 1) * cw + k), sign * 2 * A * ((A - 1) - sign * (A + 1) * cw),
             A * ((A + 1) - sign * (A - 1) * cw - k)]
        a = [(A + 1) + sign * (A - 1) * cw + k, -sign * 2 * ((A - 1) + sign * (A + 1) * cw),
             (A + 1) + sign * (A - 1) * cw - k]
    return np.array([b[0], b[1], b[2], a[0], a[1], a[2]]) / a[0]


def compress(wav, amount, sr=SR):
    """Gentle RMS compressor (up to ~3:1 above −24 dBFS): evens out loud and quiet syllables."""
    import numpy as np
    from scipy.signal import lfilter
    k = np.exp(-1.0 / (0.02 * sr))  # 20 ms level detector
    env = np.sqrt(np.maximum(lfilter([1 - k], [1, -k], wav.astype(np.float64) ** 2), 1e-12))
    threshold, ratio = 10 ** (-24 / 20), 1 + 3.3 * amount
    gain = np.where(env > threshold, (env / threshold) ** (1 / ratio - 1), 1.0)
    return (wav * gain).astype(np.float32)


def frames_db(wav, sr=SR, frame=0.03):
    import numpy as np
    n = max(1, int(sr * frame))
    usable = len(wav) // n * n
    if usable == 0:
        return np.array([-120.0])
    fr = wav[:usable].reshape(-1, n)
    return 20 * np.log10(np.sqrt((fr ** 2).mean(axis=1) + 1e-12) + 1e-12)


def track_f0(wav, sr=SR, hop=0.01):
    """Rough pitch track by autocorrelation: Hz per 10 ms frame, 0 where there is no voice."""
    import numpy as np
    from scipy.signal import medfilt
    n, step = int(sr * 0.04), int(sr * hop)
    if len(wav) < n + step:
        return np.zeros(0)
    frames = np.lib.stride_tricks.sliding_window_view(np.asarray(wav, dtype=np.float64), n)[::step]
    frames = frames - frames.mean(axis=1, keepdims=True)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    ac = np.fft.irfft(np.abs(np.fft.rfft(frames, 2 * n, axis=1)) ** 2, axis=1)[:, :n]
    lo, hi = sr // 400, sr // 60
    lag = lo + np.argmax(ac[:, lo:hi], axis=1)
    strength = ac[np.arange(len(lag)), lag] / (ac[:, 0] + 1e-12)
    voiced = (strength > 0.45) & (rms > 0.15 * np.percentile(rms, 90))
    f0 = np.where(voiced, sr / lag, 0.0)
    if voiced.sum() > 5:
        smooth = medfilt(f0, 5)  # single-frame octave jumps
        f0 = np.where(voiced & (smooth > 0), smooth, 0.0)
    return f0


def quality_report(wav, sr=SR):
    """Quick quality report of a voice sample: length, loudness, clipping, noise, pauses."""
    import numpy as np
    dur = len(wav) / sr
    db = frames_db(wav, sr)
    peak = float(np.abs(wav).max()) if len(wav) else 0.0
    clip = float((np.abs(wav) > 0.985).mean()) if len(wav) else 0.0
    noise = float(np.percentile(db, 10))
    speech = float(np.percentile(db, 90))
    voiced = float((db > noise + 12).mean())
    rms_db = float(20 * np.log10(np.sqrt((wav ** 2).mean() + 1e-12)))
    issues = []
    if dur < 3:
        issues.append("short")
    if dur > 15:
        issues.append("long")
    if clip > 0.001:
        issues.append("clipping")
    if speech - noise < 25:
        issues.append("noisy")
    if rms_db < -32:
        issues.append("quiet")
    if voiced < 0.45:
        issues.append("pauses")
    score = 100 - 18 * len(issues) - max(0, 30 - (speech - noise))
    return {"seconds": round(dur, 2), "rms_db": round(rms_db, 1), "peak": round(peak, 3), "clipping": round(clip, 4),
            "snr_db": round(speech - noise, 1), "voiced": round(voiced, 2), "issues": issues,
            "score": int(max(5, min(100, score)))}


# --------------------------------------------------------------------------
# Registries
# --------------------------------------------------------------------------
EFFECTS = {}       # name -> {"fn", "params", "tail", "title"}
POST_SYNTH = []    # hooks (wav, sr, req) -> wav, run on a finished take; wav is mono (n,) and a hook must return mono (n,)
PRE_ENHANCE = []   # hooks (req, wav, sr) -> wav, run on a sample before cleaning
TOOLS = {}         # cmd -> {"request": (in_path, out_path) -> dict, "setup": (tmpdir) -> ctx | None, "streams": False}


def register_effect(name, fn, params, *, tail=None, title=None):
    """fn(wav (n,)|(n,ch), sr, **params) -> wav. params: {key: {"min", "max", "default", "unit", "title",
    "choices"?}}; tail(sr, **params) -> seconds the effect rings on after the input ends."""
    if name in EFFECTS:
        raise ValueError("Effect already registered: %s" % name)
    if not callable(fn):
        raise ValueError("Effect %s: fn must be callable" % name)
    for key, spec in params.items():
        if "choices" in spec:
            if spec.get("default") not in spec["choices"]:
                raise ValueError("Effect %s, parameter %s: default is not among the choices" % (name, key))
            continue
        for field in ("min", "max", "default"):
            if not isinstance(spec.get(field), (int, float)) or isinstance(spec.get(field), bool):
                raise ValueError("Effect %s, parameter %s: %s must be a number" % (name, key, field))
        if not (spec["min"] < spec["max"] and spec["min"] <= spec["default"] <= spec["max"]):
            raise ValueError("Effect %s, parameter %s: need min < max and min <= default <= max" % (name, key))
    EFFECTS[name] = {"fn": fn, "params": params, "tail": tail, "title": title or name}


def _warn(text):
    print("cns: " + text, file=sys.stderr, flush=True)


def run_post_synth(wav, sr, req):
    """Runs the POST_SYNTH hooks in order. A broken hook is reported on stderr and skipped; input errors propagate."""
    for hook in list(POST_SYNTH):
        try:
            wav = hook(wav, sr, req)
        except AudioInputError:
            raise
        except Exception as e:
            _warn("post-synth hook %s failed: %s: %s" % (getattr(hook, "__name__", hook), type(e).__name__, e))
    return wav


def run_pre_enhance(req, wav, sr):
    for hook in list(PRE_ENHANCE):
        try:
            wav = hook(req, wav, sr)
        except AudioInputError:
            raise
        except Exception as e:
            _warn("pre-enhance hook %s failed: %s: %s" % (getattr(hook, "__name__", hook), type(e).__name__, e))
    return wav


# --------------------------------------------------------------------------
# Auto-loading of cns_*.py
# --------------------------------------------------------------------------
def load_modules(commands, directory=None):
    """Imports every cns_*.py next to this file (except cns_core), merging its COMMANDS into `commands`.
    A module that fails to import is reported on stderr and skipped. Returns the names loaded."""
    directory = directory or os.path.dirname(os.path.abspath(__file__))
    try:
        names = sorted(f[:-3] for f in os.listdir(directory) if f.startswith("cns_") and f.endswith(".py"))
    except OSError:
        return []
    loaded = []
    for name in names:
        if name == "cns_core":
            continue
        path = os.path.join(directory, name + ".py")
        try:
            mod = sys.modules.get(name)
            if mod is None or os.path.abspath(getattr(mod, "__file__", "") or "") != os.path.abspath(path):
                spec = importlib.util.spec_from_file_location(name, path)
                mod = importlib.util.module_from_spec(spec)
                sys.modules[name] = mod
                try:
                    spec.loader.exec_module(mod)
                except BaseException:
                    sys.modules.pop(name, None)
                    raise
            for cmd, fn in (getattr(mod, "COMMANDS", {}) or {}).items():
                if cmd in commands:
                    _warn("module %s: command %s already exists, skipped" % (name, cmd))
                else:
                    commands[cmd] = fn
            loaded.append(name)
        except Exception as e:
            _warn("module %s was skipped: %s: %s" % (name, type(e).__name__, e))
    return loaded
