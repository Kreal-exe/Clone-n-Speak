"""Effects chain of Clone'n'Speak 2.0: gain, EQ, compressor, limiter, distortion, bitcrusher, delay, chorus and
reverb. Every effect is registered through core.register_effect (the single source of truth for names, ranges and
defaults); apply_chain runs a list of them in order. Plugs into the worker through COMMANDS (fx_catalog, fx_apply),
the POST_SYNTH hook (a "chain" in a synth request) and TOOLS. numpy / scipy only. Python 3.9 compatible."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_core as core  # noqa: E402

CANONICAL = ["gain", "eq", "compressor", "limiter", "distortion", "bitcrush", "delay", "chorus", "reverb"]
SAFETY_KNEE, SAFETY_CEILING = 0.89, 0.99


def _p(lo, hi, default, unit, title):
    return {"min": lo, "max": hi, "default": default, "unit": unit, "title": title}


def _per_channel(fn):
    """Lifts fn(mono, sr, **params) to mono or (n, ch) input; channels are processed independently."""
    def run(wav, sr, **params):
        import numpy as np
        out = core.map_channels(np.asarray(wav, dtype=np.float32), lambda ch: fn(ch, sr, **params))
        return np.asarray(out, dtype=np.float32)
    run.__name__ = fn.__name__.lstrip("_")
    return run


# --------------------------------------------------------------------------
# Effects (mono kernels)
# --------------------------------------------------------------------------
def _gain(x, sr, gain_db):
    import numpy as np
    return x * np.float32(10 ** (gain_db / 20.0))


def _eq(x, sr, low_db, mid_db, high_db, low_hz, mid_hz, high_hz):
    import numpy as np
    from scipy.signal import sosfilt
    top = 0.45 * sr
    rows = []
    if low_db != 0:
        rows.append(core.biquad("low", min(low_hz, top), low_db, sr))
    if mid_db != 0:
        rows.append(core.biquad("peak", min(mid_hz, top), mid_db, sr, q=1.0))
    if high_db != 0:
        rows.append(core.biquad("high", min(high_hz, top), high_db, sr))
    if not rows:
        return x
    return sosfilt(np.array(rows), x.astype(np.float64)).astype(np.float32)


def _compressor(x, sr, threshold_db, ratio, attack_ms, release_ms, makeup_db):
    import numpy as np
    n = len(x)
    if n == 0:
        return x
    blk = max(1, int(round(sr / 1000.0)))  # 1 ms peak-detector blocks
    nb = -(-n // blk)
    a = np.abs(x)
    if nb * blk > n:
        a = np.pad(a, (0, nb * blk - n))
    peaks = a.reshape(nb, blk).max(axis=1).astype(np.float64)
    level = 20 * np.log10(np.maximum(peaks, 1e-9))
    target = np.maximum(level - threshold_db, 0.0) * (1.0 - 1.0 / ratio)  # wanted gain reduction, dB
    block_ms = blk * 1000.0 / sr
    ca = 1.0 - math.exp(-block_ms / attack_ms)
    cr = 1.0 - math.exp(-block_ms / release_ms)
    g, red = 0.0, []
    for t in target.tolist():
        g += (t - g) * (ca if t > g else cr)
        red.append(g)
    gain_db = makeup_db - np.asarray(red)
    centres = (np.arange(nb) + 0.5) * blk
    per_sample = np.interp(np.arange(n), centres, gain_db)
    return (x * 10 ** (per_sample / 20.0)).astype(np.float32)


def _decaying_max(r, k):
    """out[i] = max_j r[j] * k**(i-j), vectorised in chunks small enough for k**-i not to overflow."""
    import numpy as np
    n = len(r)
    out = np.empty(n)
    chunk = int(max(1, min(n, 25.0 / max(-math.log(k), 1e-9))))
    idx = np.arange(chunk, dtype=np.float64)
    kp, kinv = k ** idx, k ** (-idx)
    carry = 0.0
    for s in range(0, n, chunk):
        seg = r[s:s + chunk]
        m = len(seg)
        cur = np.maximum.accumulate(seg * kinv[:m]) * kp[:m]
        out[s:s + m] = np.maximum(cur, carry * kp[:m] * k)
        carry = out[s + m - 1]
    return out


def _limiter(x, sr, ceiling_db, release_ms, lookahead_ms):
    import numpy as np
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    if len(x) == 0:
        return x
    ceil = 10 ** (ceiling_db / 20.0)
    look = max(1, int(round(lookahead_ms * sr / 1000.0)))
    need = np.minimum(1.0, ceil / np.maximum(np.abs(x.astype(np.float64)), 1e-12))
    low = minimum_filter1d(need, size=2 * look + 1, mode="nearest")
    smooth = uniform_filter1d(low, size=look + 1, mode="nearest")  # window inside the min-filter's: stays <= need
    k = math.exp(-1.0 / max(release_ms / 4.0 * sr / 1000.0, 1.0))  # recovered by ~98% after release_ms
    red = _decaying_max(1.0 - smooth, k)
    y = x.astype(np.float64) * (1.0 - red)
    return np.clip(y, -ceil, ceil).astype(np.float32)


def _distortion(x, sr, drive_db, tone, mix):
    import numpy as np
    from scipy.signal import lfilter
    if mix <= 0:
        return x
    driven = x.astype(np.float64) * (2.0 * 10 ** (drive_db / 20.0))
    wet = 0.7 * driven / (1.0 + driven ** 4) ** 0.25  # soft clip, squarer than tanh: odd harmonics stand out
    fc = 800.0 * 25.0 ** tone  # tone 0 -> 800 Hz, 1 -> 20 kHz
    if fc < 0.45 * sr:
        p = math.exp(-2 * math.pi * fc / sr)
        wet = lfilter([1 - p], [1, -p], wet)
    return (x + mix * (wet - x)).astype(np.float32)


def _bitcrush(x, sr, bits, downsample, mix):
    import numpy as np
    if mix <= 0:
        return x
    bits, ds = int(round(bits)), int(round(downsample))
    wet = x[(np.arange(len(x)) // ds) * ds] if ds > 1 else x
    levels = 2.0 ** (bits - 1)  # 2**bits values from -1 to 1 - 1/levels
    wet = np.clip(np.round(wet.astype(np.float64) * levels), -levels, levels - 1) / levels
    return (x + mix * (wet - x)).astype(np.float32)


def _delay(x, sr, time_ms, feedback, mix):
    import numpy as np
    n = len(x)
    if mix <= 0 or n == 0:
        return x
    d = max(1, int(round(time_ms * sr / 1000.0)))
    xs = x.astype(np.float64)
    echo = np.zeros(n)  # echo[i] = x[i-d] + feedback * echo[i-d], one block of d samples at a time
    for s in range(d, n, d):
        e = min(n, s + d)
        echo[s:e] = xs[s - d:e - d] + feedback * echo[s - d:e - d]
    return (xs + mix * echo).astype(np.float32)


def _chorus(x, sr, rate_hz, depth_ms, mix):
    import numpy as np
    n = len(x)
    if mix <= 0 or n == 0:
        return x
    t = np.arange(n)
    pos = t - (0.010 * sr + depth_ms * 0.001 * sr * np.sin(2 * np.pi * rate_hz * t / sr))  # 10 ms +- depth
    i0 = np.floor(pos).astype(np.int64)
    frac = pos - i0
    xp = np.concatenate([np.zeros(1), x.astype(np.float64)])  # index -1 reads silence
    a = xp[np.clip(i0 + 1, 0, n)]
    b = xp[np.clip(i0 + 2, 0, n)]
    wet = a + (b - a) * frac
    return ((1.0 - mix / 2.0) * x + 0.75 * mix * wet).astype(np.float32)


_COMBS = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)  # Freeverb, tuned for 44.1 kHz
_ALLPASS = (556, 441, 341, 225)


def _comb(x, d_samples, g, damp):
    """Freeverb comb with the damping low-pass inside the loop:
    B (1 - damp z^-1 - g (1-damp) z^-D) = X (1 - damp z^-1), output = z^-D B. Solved one block of D at a time."""
    import numpy as np
    from scipy.signal import lfilter
    n = len(x)
    drive = x.copy()
    drive[1:] -= damp * x[:-1]
    b = np.zeros(n)
    zi = np.zeros(1)
    fb = g * (1.0 - damp)
    for s in range(0, n, d_samples):
        e = min(n, s + d_samples)
        u = drive[s:e]
        if s >= d_samples:
            u = u + fb * b[s - d_samples:e - d_samples]
        b[s:e], zi = lfilter([1.0], [1.0, -damp], u, zi=zi)
    y = np.zeros(n)
    if n > d_samples:
        y[d_samples:] = b[:n - d_samples]
    return y


def _allpass(x, d_samples, g=0.5):
    """y[n] = -x[n] + w[n-D], w[n] = x[n] + g w[n-D]."""
    import numpy as np
    n = len(x)
    w = np.zeros(n)
    for s in range(0, n, d_samples):
        e = min(n, s + d_samples)
        w[s:e] = x[s:e] + (g * w[s - d_samples:e - d_samples] if s >= d_samples else 0.0)
    y = -x.copy()
    if n > d_samples:
        y[d_samples:] += w[:n - d_samples]
    return y


def _reverb(x, sr, room, damping, predelay_ms, mix, tail_s):
    import numpy as np
    n = len(x)
    if mix <= 0 or n == 0:
        return x
    scale = sr / 44100.0
    pre = int(round(predelay_ms * sr / 1000.0))
    xs = x.astype(np.float64)
    if pre:
        xs = np.concatenate([np.zeros(pre), xs])[:n]
    feedback, damp = 0.7 + 0.28 * room, 0.4 * damping
    wet = np.zeros(n)
    for c in _COMBS:
        wet += _comb(xs, max(2, int(round(c * scale))), feedback, damp)
    for a in _ALLPASS:
        wet = _allpass(wet, max(2, int(round(a * scale))))
    wet *= 0.045  # Freeverb's input gain 0.015 x wet scale 3
    return ((1.0 - mix) * x + mix * wet).astype(np.float32)


# --------------------------------------------------------------------------
# Tails
# --------------------------------------------------------------------------
def _reverb_tail(sr, room=0.5, mix=0.25, tail_s=4.0, **_):
    return 0.0 if mix <= 0 else float(tail_s * room)


def _delay_tail(sr, time_ms=300, feedback=0.35, mix=0.3, **_):
    if mix <= 0:
        return 0.0
    echoes = 1 if feedback <= 0 else 1 + int(math.ceil(math.log(1e-3) / math.log(feedback)))  # down to -60 dB
    return float(min(4.0, echoes * time_ms / 1000.0))


# --------------------------------------------------------------------------
# Registration (the module may be re-executed in tests: drop the old entries first)
# --------------------------------------------------------------------------
def _register(name, fn, params, title, tail=None):
    core.EFFECTS.pop(name, None)
    core.register_effect(name, fn, params, tail=tail, title=title)


_register("gain", _per_channel(_gain), {"gain_db": _p(-24, 24, 0, "dB", "Gain")}, "Gain")
_register("eq", _per_channel(_eq), {
    "low_db": _p(-12, 12, 0, "dB", "Low"), "mid_db": _p(-12, 12, 0, "dB", "Mid"),
    "high_db": _p(-12, 12, 0, "dB", "High"), "low_hz": _p(60, 400, 120, "Hz", "Low shelf frequency"),
    "mid_hz": _p(300, 5000, 1000, "Hz", "Mid frequency"), "high_hz": _p(2000, 12000, 6000, "Hz", "High shelf frequency"),
}, "Equalizer")
_register("compressor", _per_channel(_compressor), {
    "threshold_db": _p(-60, 0, -20, "dB", "Threshold"), "ratio": _p(1, 20, 3, ":1", "Ratio"),
    "attack_ms": _p(0.5, 100, 10, "ms", "Attack"), "release_ms": _p(10, 1000, 120, "ms", "Release"),
    "makeup_db": _p(0, 24, 0, "dB", "Makeup gain"),
}, "Compressor")
_register("limiter", _per_channel(_limiter), {
    "ceiling_db": _p(-20, 0, -1, "dB", "Ceiling"), "release_ms": _p(10, 500, 80, "ms", "Release"),
    "lookahead_ms": _p(1, 10, 5, "ms", "Lookahead"),
}, "Limiter")
_register("distortion", _per_channel(_distortion), {
    "drive_db": _p(0, 40, 12, "dB", "Drive"), "tone": _p(0, 1, 0.5, "", "Tone"), "mix": _p(0, 1, 1, "", "Mix"),
}, "Distortion")
_register("bitcrush", _per_channel(_bitcrush), {
    "bits": _p(1, 16, 8, "bit", "Bit depth"), "downsample": _p(1, 32, 1, "x", "Downsample"),
    "mix": _p(0, 1, 1, "", "Mix"),
}, "Bitcrusher")
_register("delay", _per_channel(_delay), {
    "time_ms": _p(10, 2000, 300, "ms", "Time"), "feedback": _p(0, 0.95, 0.35, "", "Feedback"),
    "mix": _p(0, 1, 0.3, "", "Mix"),
}, "Delay", tail=_delay_tail)
_register("chorus", _per_channel(_chorus), {
    "rate_hz": _p(0.1, 5, 0.8, "Hz", "Rate"), "depth_ms": _p(0.5, 10, 3, "ms", "Depth"),
    "mix": _p(0, 1, 0.5, "", "Mix"),
}, "Chorus")
_register("reverb", _per_channel(_reverb), {
    "room": _p(0, 1, 0.5, "", "Room size"), "damping": _p(0, 1, 0.5, "", "Damping"),
    "predelay_ms": _p(0, 100, 10, "ms", "Pre-delay"), "mix": _p(0, 1, 0.25, "", "Mix"),
    "tail_s": _p(0, 4, 4.0, "s", "Tail length"),
}, "Reverb", tail=_reverb_tail)


# --------------------------------------------------------------------------
# The chain
# --------------------------------------------------------------------------
def _resolve(chain):
    """Validates a chain and returns [(name, params)] for the effects that are on, parameters clamped and
    completed with defaults. Raises AudioInputError("bad_param") (a ValueError) for anything unusable."""
    if chain is None:
        return []
    if not isinstance(chain, (list, tuple)):
        raise core.AudioInputError("bad_param", "The effects chain must be a list of effects.")
    steps = []
    for item in chain:
        if not isinstance(item, dict) or not isinstance(item.get("type"), str):
            raise core.AudioInputError("bad_param", "Every effect in the chain needs a type.")
        name = item["type"]
        entry = core.EFFECTS.get(name)
        if entry is None:
            raise core.AudioInputError("bad_param", "Unknown effect '%s'" % name)
        if not item.get("on", True):
            continue
        given = item.get("params") or {}
        if not isinstance(given, dict):
            raise core.AudioInputError("bad_param", "The parameters of '%s' must be an object." % name)
        params = {}
        for key, spec in entry["params"].items():
            v = given.get(key, spec["default"])
            if "choices" in spec:
                if v not in spec["choices"]:
                    raise core.AudioInputError("bad_param", "Parameter '%s' of '%s' must be one of %s."
                                               % (key, name, ", ".join(str(c) for c in spec["choices"])))
                params[key] = v
                continue
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
                raise core.AudioInputError("bad_param", "Parameter '%s' of '%s' must be a number." % (key, name))
            params[key] = min(max(float(v), spec["min"]), spec["max"])
        steps.append((name, params))
    return steps


def tail_seconds(chain, sr):
    """Seconds the chain rings on after the input ends (reverb and delay tails); 0 without them."""
    total = 0.0
    for name, params in _resolve(chain):
        tail = core.EFFECTS[name]["tail"]
        if tail is not None:
            total += max(0.0, float(tail(sr, **params)))
    return total


def _safety(y):
    """Soft limiter at the end of the chain: nothing happens while the peak stays within 1.0; above that a smooth
    knee (0.89) toward a 0.99 ceiling, so nothing the chain makes can clip. Also removes NaN / inf."""
    import numpy as np
    y = np.nan_to_num(y, nan=0.0, posinf=1.0, neginf=-1.0)
    if y.size and float(np.abs(y).max()) > 1.0:
        a = np.abs(y)
        span = SAFETY_CEILING - SAFETY_KNEE
        soft = SAFETY_KNEE + span * np.tanh((a - SAFETY_KNEE) / span)
        y = np.where(a > SAFETY_KNEE, np.sign(y) * soft, y)
    return y.astype(np.float32)


def apply_chain(wav, sr, chain, *, extend=True):
    """Runs the effects in order on mono (n,) or stereo (n, ch) audio. extend=True appends tail_seconds(chain)
    of silence first, so reverb and echoes ring out. Returns float32 of the same shape (longer by the tail)."""
    import numpy as np
    steps = _resolve(chain)
    y = np.array(wav, dtype=np.float32)
    if not steps:
        return y
    extra = int(round(tail_seconds(chain, sr) * sr)) if extend else 0
    if extra:
        y = np.concatenate([y, np.zeros((extra,) + y.shape[1:], dtype=np.float32)])
    for name, params in steps:
        y = np.asarray(core.EFFECTS[name]["fn"](y, sr, **params), dtype=np.float32)
    if extra:
        fade = min(extra, int(0.05 * sr))  # the tail ends in a short fade, never a cut
        if fade > 1:
            ramp = np.linspace(1.0, 0.0, fade, dtype=np.float32)
            y[-fade:] *= ramp if y.ndim == 1 else ramp[:, None]
    return _safety(y)


# --------------------------------------------------------------------------
# Worker plumbing
# --------------------------------------------------------------------------
def fx_catalog(req=None):
    ids = [n for n in CANONICAL if n in core.EFFECTS] + [n for n in core.EFFECTS if n not in CANONICAL]
    return {"effects": [{"id": n, "title": core.EFFECTS[n]["title"],
                         "params": {k: dict(v) for k, v in core.EFFECTS[n]["params"].items()}} for n in ids]}


def fx_apply(req):
    chain = req.get("chain") or []
    _resolve(chain)  # bad parameters fail before any file is touched
    out = req.get("out")
    if not out:
        raise core.AudioInputError("bad_param", "Choose where to save the result.")
    wav, rate = core.read_audio(req["audio"], mono=False, sr=None)
    if req.get("dry_out"):
        core.write_audio(req["dry_out"], wav, rate)
    tail = tail_seconds(chain, rate)
    seconds = core.write_audio(out, apply_chain(wav, rate, chain, extend=True), rate)
    return {"path": out, "seconds": round(seconds, 3), "tail": round(tail, 3)}


def fx_post_synth(wav, sr, req):
    chain = req.get("chain")
    if not chain:
        return wav
    _resolve(chain)
    if req.get("dry_out"):
        core.write_audio(req["dry_out"], wav, sr)
    y = apply_chain(wav, sr, chain, extend=True)
    return y if y.ndim == 1 else y.mean(axis=1)


core.POST_SYNTH[:] = [h for h in core.POST_SYNTH if getattr(h, "__name__", "") != "fx_post_synth"]
core.POST_SYNTH.append(fx_post_synth)

COMMANDS = {"fx_catalog": fx_catalog, "fx_apply": fx_apply}

core.TOOLS["fx_apply"] = {"request": lambda i, o: {
    "cmd": "fx_apply", "audio": i, "out": o,
    "chain": [{"type": "reverb"}] + [{"type": n} for n in CANONICAL if n != "reverb"]}}
