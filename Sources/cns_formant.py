"""Formant shift and pitch shift (Clone'n'Speak 2.0), plain numpy.

formant_shift moves the spectral envelope (the "size of the vocal tract") and leaves pitch and duration alone:
per STFT frame the envelope is the liftered cepstrum of the log magnitude, the excitation is |X| / envelope, the
envelope is warped along the frequency axis and multiplied back, the phase is kept.

pitch_shift stretches the signal in time with a phase vocoder (identity phase locking around spectral peaks, so
partials keep their phase relationship) and resamples it back to the original length.

Python 3.9 compatible; numpy and scipy are imported inside the functions.
"""
import cns_core as core

_N = 2048          # STFT window
_HOP = 512         # formant analysis / synthesis hop
_CHUNK = 256       # frames processed at once (bounds the memory on long files)
RATIO_MIN, RATIO_MAX = 0.5, 2.0
ST_MIN, ST_MAX = -12.0, 12.0


def _lifter_order(sr):
    return max(8, int(round(sr / 600.0)))


def _clean(wav):
    import numpy as np
    return np.nan_to_num(np.asarray(wav, dtype=np.float32), nan=0.0, posinf=0.0, neginf=0.0)


# --------------------------------------------------------------------------
# Formant shift
# --------------------------------------------------------------------------
def _formant_mono(x, sr, ratio):
    import numpy as np
    n = len(x)
    N, H = _N, _HOP
    win = np.hanning(N + 1)[:N]  # periodic Hann
    L = _lifter_order(sr)
    nframes = (n + N) // H + 1
    total = (nframes - 1) * H + N
    pad = np.zeros(total, dtype=np.float64)
    pad[N:N + n] = x
    out = np.zeros(total, dtype=np.float64)
    wsum = np.zeros(total, dtype=np.float64)
    K = N // 2 + 1
    src = np.clip(np.arange(K, dtype=np.float64) / ratio, 0, K - 1)   # env'(k) = env(k / ratio)
    lo = np.floor(src).astype(int)
    hi = np.minimum(lo + 1, K - 1)
    frac = src - lo
    lifter = np.zeros(N)
    lifter[:L + 1] = 1.0
    lifter[N - L:] = 1.0
    w2 = win * win
    for c0 in range(0, nframes, _CHUNK):
        c1 = min(nframes, c0 + _CHUNK)
        idx = (np.arange(c0, c1) * H)[:, None] + np.arange(N)[None, :]
        spec = np.fft.rfft(pad[idx] * win, axis=1)
        logm = np.log(np.abs(spec) + 1e-9)
        cep = np.fft.irfft(logm, n=N, axis=1) * lifter
        logenv = np.fft.rfft(cep, axis=1).real
        warped = logenv[:, lo] * (1 - frac) + logenv[:, hi] * frac
        new = spec * np.exp(warped - logenv)  # |X| / env * env' with the phase of X
        frames = np.fft.irfft(new, n=N, axis=1) * win
        for j, m in enumerate(range(c0, c1)):
            out[m * H:m * H + N] += frames[j]
            wsum[m * H:m * H + N] += w2
    y = np.where(wsum > 1e-3, out / np.maximum(wsum, 1e-3), 0.0)
    return y[N:N + n].astype(np.float32)


def formant_shift(wav, sr, ratio):
    """Scales the spectral envelope along the frequency axis by `ratio` (clamped to 0.5..2.0): above 1 the voice
    gets smaller / brighter, below 1 bigger / darker. Pitch and duration stay. ratio 1.0 returns the input."""
    wav = _clean(wav)
    ratio = float(min(max(float(ratio), RATIO_MIN), RATIO_MAX))
    if ratio == 1.0 or wav.shape[0] == 0:
        return wav
    return core.map_channels(wav, lambda ch: _formant_mono(ch, int(sr), ratio))


# --------------------------------------------------------------------------
# Pitch shift
# --------------------------------------------------------------------------
def _stretch_mono(x, p, q, N=2048, Hs=512):
    """Phase-vocoder time stretch by p / q (output length ~ len(x) * p / q)."""
    import numpy as np
    from scipy.ndimage import maximum_filter1d
    n = len(x)
    s = p / float(q)
    Ha = Hs / s
    K = N // 2 + 1
    win = np.hanning(N + 1)[:N]
    w2 = win * win
    nframes = int(np.ceil(n / Ha)) + 2
    pos = np.round(np.arange(nframes) * Ha).astype(np.int64)
    pad = np.zeros(int(pos[-1]) + N + N // 2, dtype=np.float64)
    pad[N // 2:N // 2 + n] = x
    total = (nframes - 1) * Hs + N
    out = np.zeros(total, dtype=np.float64)
    wsum = np.zeros(total, dtype=np.float64)
    omega = 2 * np.pi * np.arange(K) / N
    karange = np.arange(K)
    prev_phi = prev_psi = None
    prev_pos = 0
    for c0 in range(0, nframes, _CHUNK):
        c1 = min(nframes, c0 + _CHUNK)
        idx = pos[c0:c1][:, None] + np.arange(N)[None, :]
        spec = np.fft.rfft(pad[idx] * win, axis=1)
        mag = np.abs(spec)
        phi = np.angle(spec)
        peaks = (mag >= maximum_filter1d(mag, size=5, axis=1, mode="nearest")) & (mag > 0)
        res = np.empty_like(spec)
        for j in range(c1 - c0):
            m = c0 + j
            if prev_phi is None:
                psi = phi[j].copy()
            else:
                da = float(pos[m] - prev_pos)
                dev = phi[j] - prev_phi - omega * da
                dev -= 2 * np.pi * np.round(dev / (2 * np.pi))
                prop = prev_psi + (omega + dev / da) * Hs
                P = np.flatnonzero(peaks[j])
                if len(P) == 0:
                    psi = prop
                else:
                    near = P[np.searchsorted((P[:-1] + P[1:]) / 2.0, karange)]
                    psi = prop[near] + (phi[j] - phi[j][near])
            prev_phi, prev_psi, prev_pos = phi[j], psi, pos[m]
            res[j] = mag[j] * np.exp(1j * psi)
        frames = np.fft.irfft(res, n=N, axis=1) * win
        for j, m in enumerate(range(c0, c1)):
            out[m * Hs:m * Hs + N] += frames[j]
            wsum[m * Hs:m * Hs + N] += w2
    y = np.where(wsum > 1e-3, out / np.maximum(wsum, 1e-3), 0.0)
    want = int(round(n * s))
    y = y[N // 2:N // 2 + want]
    if len(y) < want:
        y = np.pad(y, (0, want - len(y)))
    return y


def _pitch_mono(x, sr, factor):
    import numpy as np
    from fractions import Fraction
    from scipy.signal import resample_poly
    frac = Fraction(factor).limit_denominator(100)
    p, q = frac.numerator, frac.denominator
    n = len(x)
    stretched = _stretch_mono(x.astype(np.float64), p, q)
    y = resample_poly(stretched, q, p)  # shorter by p / q: pitch goes up by p / q
    if len(y) < n:
        y = np.pad(y, (0, n - len(y)))
    return y[:n].astype(np.float32)


def pitch_shift(wav, sr, semitones, preserve_formants=False):
    """Shifts the pitch by `semitones` (clamped to -12..12) and keeps the duration. With preserve_formants the
    spectral envelope is moved back, so the voice changes pitch but not character."""
    wav = _clean(wav)
    st = float(min(max(float(semitones), ST_MIN), ST_MAX))
    if st == 0.0 or wav.shape[0] == 0:
        return wav
    factor = 2.0 ** (st / 12.0)
    y = core.map_channels(wav, lambda ch: _pitch_mono(ch, int(sr), factor))
    if preserve_formants:
        y = formant_shift(y, sr, 1.0 / factor)
    return y


# --------------------------------------------------------------------------
# Effects, commands, tools
# --------------------------------------------------------------------------
def _safe(y):
    import numpy as np
    return np.clip(np.nan_to_num(y, nan=0.0, posinf=1.0, neginf=-1.0), -1.0, 1.0).astype(np.float32)


def _fx_pitch(wav, sr, semitones=0.0, preserve_formants=0):
    return _safe(pitch_shift(wav, sr, semitones, bool(round(float(preserve_formants)))))


def _fx_formant(wav, sr, ratio=1.0):
    return _safe(formant_shift(wav, sr, ratio))


core.register_effect(
    "pitch", _fx_pitch,
    {"semitones": {"min": -12, "max": 12, "default": 0, "unit": "st", "title": "Pitch"},
     "preserve_formants": {"min": 0, "max": 1, "default": 0, "unit": "", "title": "Keep voice character"}},
    title="Pitch")
core.register_effect(
    "formant", _fx_formant,
    {"ratio": {"min": 0.5, "max": 2.0, "default": 1.0, "unit": "x", "title": "Formants"}},
    title="Formants")


def _number(req, key, default):
    try:
        v = float(req.get(key, default))
    except (TypeError, ValueError):
        v = float("nan")
    if v != v or v in (float("inf"), float("-inf")):
        raise core.AudioInputError("bad_param", "The value for '%s' is not a number. Enter a number." % key)
    return v


def _run(req, process):
    wav, sr = core.read_audio(req["audio"], mono=False)
    y = _safe(process(wav, sr))
    seconds = core.write_audio(req["out"], y, sr)
    return {"path": req["out"], "seconds": seconds}


def formant_apply(req):
    ratio = _number(req, "ratio", 1.0)
    return _run(req, lambda w, sr: formant_shift(w, sr, ratio))


def pitch_apply(req):
    st = _number(req, "semitones", 0.0)
    keep = bool(_number(req, "preserve_formants", 0))
    return _run(req, lambda w, sr: pitch_shift(w, sr, st, keep))


COMMANDS = {"formant_apply": formant_apply, "pitch_apply": pitch_apply}

core.TOOLS["formant_apply"] = {"request": lambda i, o: {"cmd": "formant_apply", "audio": i, "out": o, "ratio": 1.25}}
core.TOOLS["pitch_apply"] = {"request": lambda i, o: {"cmd": "pitch_apply", "audio": i, "out": o, "semitones": 4,
                                                      "preserve_formants": 1}}
