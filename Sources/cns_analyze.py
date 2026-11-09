"""Analyzer data (Clone'n'Speak 2.0): waveform peaks, an 8-bit mel-like spectrogram, a pitch curve and a spectral
centroid curve, all computed here so the app only draws. Python 3.9 compatible; numpy / scipy load inside functions.

The spectrogram is not a full STFT: only `cols` windows are taken, centred on the column centres, so the cost
hardly depends on the file length. Everything is computed on a mono signal of at most 16 kHz.
"""
import os

import cns_core as core

WORK_SR = 16000
WINDOW = 2048
F0_WINDOW_S = 0.04
FMIN = 40.0
DB_FLOOR = -90.0
DB_CEIL = 0.0
MAX_PEAKS = 2000
CHUNK = 256  # columns per batch: bounds the memory of the frame matrices


def _bad(msg):
    raise core.AudioInputError("bad_param", msg)


def _int_param(req, key, default, lo, hi):
    v = req.get(key, default)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != int(v) or not lo <= v <= hi:
        _bad("%s must be a whole number from %d to %d." % (key, lo, hi))
    return int(v)


def _mel(f):
    import numpy as np
    return 2595.0 * np.log10(1.0 + np.asarray(f, dtype=np.float64) / 700.0)


def _mel_inv(m):
    import numpy as np
    return 700.0 * (10.0 ** (np.asarray(m, dtype=np.float64) / 2595.0) - 1.0)


def _row_hz(rows, fmax):
    import numpy as np
    return _mel_inv(np.linspace(_mel(FMIN), _mel(fmax), rows))


def _filterbank(row_hz, sr):
    """(bins, rows) weights: a triangle around each row frequency, never narrower than one FFT bin, summing to 1."""
    import numpy as np
    freqs = np.fft.rfftfreq(WINDOW, 1.0 / sr)
    step = sr / float(WINDOW)
    rows = len(row_hz)
    gaps = np.diff(row_hz)
    half = np.empty(rows)
    half[1:-1] = np.maximum(gaps[1:], gaps[:-1])
    half[0], half[-1] = gaps[0], gaps[-1]
    half = np.maximum(half, step)
    w = np.maximum(0.0, 1.0 - np.abs(freqs[:, None] - row_hz[None, :]) / half[None, :])
    s = w.sum(axis=0)
    s[s == 0] = 1.0
    return (w / s).astype(np.float32), freqs


def _peaks(mono, count):
    import numpy as np
    n = len(mono)
    k = max(1, min(count, n))
    edges = np.linspace(0, n, k + 1).astype(np.int64)[:-1]
    mn = np.minimum.reduceat(mono, edges)
    mx = np.maximum.reduceat(mono, edges)
    return [[round(float(a), 4) + 0.0, round(float(b), 4) + 0.0] for a, b in zip(mn, mx)]


def _f0_chunk(x, starts, win, sr):
    import numpy as np
    idx = starts[:, None] + np.arange(win)[None, :]
    fr = x[idx].astype(np.float64)
    fr -= fr.mean(axis=1, keepdims=True)
    rms = np.sqrt((fr ** 2).mean(axis=1))
    ac = np.fft.irfft(np.abs(np.fft.rfft(fr, 2 * win, axis=1)) ** 2, axis=1)[:, :win]
    lo, hi = sr // 400, sr // 60
    lag = lo + np.argmax(ac[:, lo:hi], axis=1)
    r = np.arange(len(lag))
    strength = ac[r, lag] / (ac[:, 0] + 1e-12)
    a, b, c = ac[r, lag - 1], ac[r, lag], ac[r, np.minimum(lag + 1, win - 1)]
    den = a - 2 * b + c
    shift = np.where(np.abs(den) > 1e-12, 0.5 * (a - c) / np.where(den == 0, 1, den), 0.0)
    return sr / (lag + np.clip(shift, -1, 1)), strength, rms


def _f0_curve(xp, pad, centers, sr):
    import numpy as np
    from scipy.signal import medfilt
    win = int(sr * F0_WINDOW_S)
    freq, strength, rms = [], [], []
    for i in range(0, len(centers), CHUNK):
        starts = centers[i:i + CHUNK] + pad - win // 2
        f, s, r = _f0_chunk(xp, starts, win, sr)
        freq.append(f)
        strength.append(s)
        rms.append(r)
    freq, strength, rms = np.concatenate(freq), np.concatenate(strength), np.concatenate(rms)
    voiced = (strength > 0.45) & (rms > 0.15 * np.percentile(rms, 90)) & (rms > 1e-5)
    f0 = np.where(voiced, freq, 0.0)
    if voiced.sum() > 5:
        smooth = medfilt(f0, 5)  # single-frame octave jumps
        f0 = np.where(voiced & (smooth > 0), smooth, 0.0)
    return f0


def _analyze(req, path):
    import numpy as np
    cols = _int_param(req, "cols", 1200, 200, 2000)
    rows = _int_param(req, "rows", 256, 64, 384)
    out_dir = os.path.abspath(os.path.normpath(str(req["out_dir"])))
    wav, rate = core.read_audio(path, mono=False)
    channels = 1 if wav.ndim == 1 else wav.shape[1]
    mono = wav if wav.ndim == 1 else wav.mean(axis=1).astype(np.float32)
    seconds = len(mono) / float(rate)
    peak = float(np.abs(wav).max())
    rms_db = float(20 * np.log10(np.sqrt(float((mono.astype(np.float64) ** 2).mean()) + 1e-12)))
    peaks = _peaks(mono, MAX_PEAKS)
    del wav
    core.emit_progress(0.2)

    sr = min(rate, WORK_SR)
    x = core.resample(mono, rate, sr) if rate != sr else mono
    fmax = min(sr / 2.0, 8000.0)
    row_hz = _row_hz(rows, fmax)
    fb, freqs = _filterbank(row_hz, sr)
    pad = WINDOW
    xp = np.concatenate([np.zeros(pad, np.float32), x.astype(np.float32), np.zeros(pad, np.float32)])
    centers = np.round((np.arange(cols) + 0.5) * len(x) / cols).astype(np.int64)
    silent = float(np.abs(x).max()) < 1e-6 if len(x) else True

    spec = np.zeros((rows, cols), dtype=np.uint8)
    centroid = np.zeros(cols)
    f0 = np.zeros(cols)
    if not silent:
        hann = np.hanning(WINDOW + 1)[:-1].astype(np.float32)
        band = freqs <= fmax
        power = np.empty((cols, rows), dtype=np.float32)
        for i in range(0, cols, CHUNK):
            starts = centers[i:i + CHUNK] + pad - WINDOW // 2
            fr = xp[starts[:, None] + np.arange(WINDOW)[None, :]] * hann
            p = np.abs(np.fft.rfft(fr, axis=1)) ** 2
            power[i:i + CHUNK] = p @ fb
            pb = p[:, band]
            tot = pb.sum(axis=1)
            centroid[i:i + CHUNK] = np.where(tot > 1e-9, (pb @ freqs[band]) / np.maximum(tot, 1e-30), 0.0)
        ref = float(power.max())
        if ref > 0:
            db = 10.0 * np.log10(np.maximum(power, 1e-30) / ref)
            level = np.clip((db - DB_FLOOR) / (DB_CEIL - DB_FLOOR), 0.0, 1.0)
            spec = np.ascontiguousarray(np.round(level * 255.0).astype(np.uint8).T)
        core.emit_progress(0.7)
        f0 = _f0_curve(xp, pad, centers, sr)
    voiced = f0[f0 > 0]
    median = round(float(np.median(voiced)), 1) if len(voiced) else None

    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, "spectrogram.u8")
    tmp = target + ".part"
    try:
        with open(tmp, "wb") as f:
            f.write(spec.tobytes())
        os.replace(tmp, target)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    col_s = seconds / cols
    return {
        "seconds": round(seconds, 4), "sr": int(rate), "channels": int(channels),
        "rms_db": round(rms_db, 2), "peak": round(peak, 4),
        "waveform": {"peaks": peaks},
        "spectrogram": {"path": target, "cols": cols, "rows": rows, "fmin": FMIN, "fmax": float(fmax),
                        "db_floor": DB_FLOOR, "db_ceil": DB_CEIL,
                        "row_hz": [round(float(v), 2) for v in row_hz], "col_s": col_s},
        "f0": {"hop_s": col_s, "values": [round(float(v), 1) for v in f0], "median_hz": median},
        "centroid": {"hop_s": col_s, "values_hz": [round(float(v), 1) for v in centroid]},
    }


def cmd_analyze_audio(req):
    """Waveform peaks, spectrogram (8-bit file in out_dir), pitch curve and centroid curve of an audio file."""
    if not req.get("audio") or not req.get("out_dir"):
        _bad("Choose an audio file to analyze.")
    return _analyze(req, req["audio"])


COMMANDS = {"analyze_audio": cmd_analyze_audio}


def _tool_request(in_path, out_path):
    return {"cmd": "analyze_audio", "audio": in_path, "out_dir": os.path.join(os.path.dirname(out_path), "analysis")}


def _tool_setup(tmpdir):
    # The analyzer writes no audio. The shared input matrix expects an output WAV, so the cleanup hands it the input.
    def finish():
        import shutil
        src, dst = os.path.join(tmpdir, "in.wav"), os.path.join(tmpdir, "out.wav")
        if os.path.exists(src) and not os.path.exists(dst):
            shutil.copyfile(src, dst)
    return finish


core.TOOLS["analyze_audio"] = {"request": _tool_request, "setup": _tool_setup, "streams": False}
