"""Extended voice-sample check and comparison of several samples (Clone'n'Speak 2.0).

sample_check: everything the old `analyze` reported (core.quality_report on 24 kHz mono) plus silence at the edges,
the longest pause, problem regions in seconds (they feed OVWaveformView.regions), mains hum and advice codes.
compare_samples: loudness / noise per sample, pairwise similarity of the energy envelopes (duplicates) and outliers.
Only numpy / scipy. Python 3.9 compatible. Never prints to stdout.
"""
import cns_core as core

SR = core.SR
FRAME = 0.03            # seconds per level frame (as in cmd_enhance)
MAX_FILES = 12
PAUSE_REGION_S = 0.7    # a voiceless stretch this long between voiced parts is a pause region
LONG_PAUSE_S = 1.5      # ... and this long is worth advice
EDGE_ADVICE_S = 0.35    # silence at an edge this long: advise trimming
CLIP_LEVEL = 0.985
EDGE_DEBOUNCE = 3       # voiced frames in a row that end the silence at an edge


def _runs(mask):
    """[(start, end)) index pairs of the True runs of a boolean array."""
    import numpy as np
    m = np.concatenate(([0], np.asarray(mask).astype(np.int8), [0]))
    d = np.diff(m)
    return list(zip(np.flatnonzero(d == 1).tolist(), np.flatnonzero(d == -1).tolist()))


def _merge(runs, gap):
    out = []
    for a, b in runs:
        if out and a - out[-1][1] <= gap:
            out[-1] = (out[-1][0], b)
        else:
            out.append((a, b))
    return out


def _region(start, end, kind, severity):
    return {"start": round(float(start), 3), "end": round(float(end), 3), "kind": kind,
            "severity": round(float(min(1.0, max(0.0, severity))), 2)}


def _clipping_regions(wav):
    import numpy as np
    hit = np.abs(wav) >= CLIP_LEVEL
    runs = [(a, b) for a, b in _runs(hit) if b - a >= 3]
    out = []
    for a, b in _merge(runs, int(0.05 * SR)):
        count = int(hit[a:b].sum())
        out.append(_region(a / SR, b / SR, "clipping", 0.3 + count / (0.05 * SR)))
    return out


def _pitched_frames(wav, nframes):
    """Boolean per 30 ms frame: a pitch was found in or right next to it (voice, as opposed to noise)."""
    import numpy as np
    f0 = core.track_f0(wav, SR, hop=0.01)
    per = int(round(FRAME / 0.01))
    out = np.zeros(nframes, dtype=bool)
    for k in range(nframes):
        seg = f0[k * per:(k + 1) * per]
        out[k] = bool(len(seg) and (seg > 0).any())
    return np.convolve(out.astype(np.int8), np.ones(3, dtype=np.int8), mode="same") > 0


def _noise_regions(db, pitched):
    """0.5 s windows that are mostly voiceless and clearly louder than the noise floor of the file."""
    import numpy as np
    n = len(db)
    win = int(round(0.5 / FRAME))
    if n < win:
        return []
    floor = max(float(np.percentile(db, 10)), -60.0)
    nonvoice = ~pitched
    flagged = nonvoice & (db >= floor + 10)
    hits = []
    for s in range(0, n - win + 1, 3):
        nv = int(nonvoice[s:s + win].sum())
        fl = int(flagged[s:s + win].sum())
        hits.append(nv >= win / 2 and fl >= win / 2 and fl >= 0.6 * nv)
    runs = []
    for a, b in _runs(np.array(hits)):
        lo, hi = a * 3, (b - 1) * 3 + win
        idx = np.flatnonzero(flagged[lo:hi])
        if len(idx):
            runs.append((lo + int(idx[0]), lo + int(idx[-1]) + 1))
    out = []
    for a, b in _merge(runs, 2):
        excess = float(db[a:b][flagged[a:b]].mean()) - floor - 10
        out.append(_region(a * FRAME, b * FRAME, "noise", 0.3 + excess / 25.0))
    return out


def _low_level_regions(db, voiced):
    import numpy as np
    if voiced.sum() < 5:
        return []
    med = float(np.median(db[voiced]))
    low = voiced & (db < med - 12)
    out = []
    for a, b in _merge(_runs(low), 3):
        if b - a >= int(round(0.2 / FRAME)):
            out.append(_region(a * FRAME, b * FRAME, "low_level", (med - float(db[a:b].mean()) - 12) / 18.0 + 0.3))
    return out


def _hum(wav):
    """(50 | 60 | None, strength in dB): a narrow peak at the mains frequency, 12 dB over its neighbours, with a harmonic."""
    import numpy as np
    from scipy.signal import welch
    if len(wav) < SR * 2:
        return None, 0.0
    f, p = welch(wav.astype(np.float64), fs=SR, nperseg=16384, noverlap=8192)

    def peak_db(fc):
        band = (f >= fc - 1.5) & (f <= fc + 1.5)
        side = ((f >= fc - 12) & (f <= fc - 4)) | ((f >= fc + 4) & (f <= fc + 12))
        if not band.any() or not side.any():
            return 0.0
        return 10 * np.log10((p[band].max() + 1e-20) / (np.median(p[side]) + 1e-20))

    # The fundamental must stand 12 dB over its neighbours; a harmonic (100/150 or 120/180 Hz) must show too, but speech
    # fills that range with its own harmonics, so for it a few dB over the neighbours is enough.
    best, best_score = None, 0.0
    for base in (50, 60):
        levels = [peak_db(base * k) for k in (1, 2, 3, 4)]
        if levels[0] >= 12 and max(levels[1:]) >= 2 and levels[0] > best_score:
            best, best_score = base, levels[0]
    return best, (best_score if best else 0.0)


def check(wav):
    """The full report for a 24 kHz mono signal."""
    import numpy as np
    report = core.quality_report(wav, SR)
    dur = len(wav) / float(SR)
    db = core.frames_db(wav, SR, FRAME)
    nfr = len(db)
    voiced = db > max(float(np.percentile(db, 10)) + 10, -55.0)
    regions = _clipping_regions(wav)

    lead = tail = 0.0
    longest = None
    solid = [(a, b) for a, b in _runs(voiced) if b - a >= EDGE_DEBOUNCE]  # a lone click does not end the silence
    if voiced.any():
        first, last = (solid[0][0], solid[-1][1]) if solid else (int(np.argmax(voiced)), nfr - int(np.argmax(voiced[::-1])))
        lead, tail = first * FRAME, max(0.0, dur - last * FRAME)
        for a, b in _runs(~voiced[first:last]):
            a, b = a + first, b + first
            sec = (b - a) * FRAME
            if sec >= PAUSE_REGION_S and (longest is None or sec > longest["seconds"]):
                longest = {"start": round(a * FRAME, 3), "end": round(b * FRAME, 3), "seconds": round(sec, 2)}
            if sec >= PAUSE_REGION_S:
                regions.append(_region(a * FRAME, b * FRAME, "pause", sec / 3.0))
    else:
        lead = dur
    regions += _low_level_regions(db, voiced)
    regions += _noise_regions(db, _pitched_frames(wav, nfr))
    hum_hz, hum_db = _hum(wav)
    if hum_hz:
        regions.append(_region(0.0, dur, "hum", 0.3 + (hum_db - 12) / 24.0))
    regions.sort(key=lambda r: (r["start"], r["end"]))

    issues = report["issues"]
    advice = []
    if voiced.any() and lead > EDGE_ADVICE_S:
        advice.append("trim_start")
    if voiced.any() and tail > EDGE_ADVICE_S:
        advice.append("trim_end")
    if "noisy" in issues or any(r["kind"] == "noise" for r in regions):
        advice.append("denoise")
    if "quiet" in issues:
        advice.append("too_quiet")
    if "clipping" in issues or any(r["kind"] == "clipping" for r in regions):
        advice.append("clipping")
    if longest is not None and longest["seconds"] >= LONG_PAUSE_S:
        advice.append("long_pause")
    if hum_hz:
        advice.append("hum")
    report.update({"lead_silence_s": round(lead, 2), "tail_silence_s": round(tail, 2), "longest_pause": longest,
                   "regions": regions, "hum_hz": hum_hz, "advice": advice})
    return report


def cmd_sample_check(req):
    wav, _ = core.read_audio(req["audio"], sr=SR, mono=True)
    return check(wav)


# --------------------------------------------------------------------------
# Comparison
# --------------------------------------------------------------------------
def _envelope(wav):
    import numpy as np
    n = int(SR * 0.02)
    usable = len(wav) // n * n
    if usable == 0:
        return np.zeros(1)
    fr = wav[:usable].astype(np.float64).reshape(-1, n)
    return np.sqrt((fr ** 2).mean(axis=1))


def _best_ncc(x, y):
    """Maximum over time shifts of the normalised cross-correlation of two envelopes (overlap >= 80 % of the
    shorter one)."""
    import numpy as np
    from scipy.signal import fftconvolve
    nx, ny = len(x), len(y)
    min_ov = max(5, int(0.8 * min(nx, ny)))
    if min(nx, ny) < 5:
        return 0.0
    full = fftconvolve(x, y[::-1], mode="full")  # index k <-> shift L = k - (ny - 1): y[0] sits on x[L]
    lags = np.arange(-(ny - 1), nx)
    lo = np.maximum(lags, 0)
    hi = np.minimum(nx, lags + ny)
    n = hi - lo
    ok = n >= min_ov
    if not ok.any():
        return 0.0
    cx = np.concatenate(([0.0], np.cumsum(x)))
    cxx = np.concatenate(([0.0], np.cumsum(x * x)))
    cy = np.concatenate(([0.0], np.cumsum(y)))
    cyy = np.concatenate(([0.0], np.cumsum(y * y)))
    ylo, yhi = lo - lags, hi - lags
    sx, sxx = cx[hi] - cx[lo], cxx[hi] - cxx[lo]
    sy, syy = cy[yhi] - cy[ylo], cyy[yhi] - cyy[ylo]
    with np.errstate(divide="ignore", invalid="ignore"):
        nn = np.maximum(n, 1)
        num = full - sx * sy / nn
        den = np.sqrt(np.maximum(sxx - sx * sx / nn, 0) * np.maximum(syy - sy * sy / nn, 0))
        ncc = np.where(ok & (den > 1e-12), num / den, -1.0)
    return float(np.clip(ncc.max(), -1.0, 1.0))


def cmd_compare_samples(req):
    import numpy as np
    paths = req.get("audios")
    if not isinstance(paths, (list, tuple)) or not paths:
        raise core.AudioInputError("bad_param", "Choose at least one sample to compare.")
    if len(paths) > MAX_FILES:
        raise core.AudioInputError("bad_param", "Too many samples: compare at most %d at a time." % MAX_FILES)
    samples, envs = [], []
    for i, path in enumerate(paths):
        wav, _ = core.read_audio(path, sr=SR, mono=True)
        r = core.quality_report(wav, SR)
        samples.append({"path": str(path), "seconds": r["seconds"], "rms_db": r["rms_db"], "peak": r["peak"],
                        "snr_db": r["snr_db"], "issues": r["issues"]})
        envs.append(_envelope(wav))
        core.emit_progress((i + 1) / float(len(paths)))
    pairs = []
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            sim = _best_ncc(envs[i], envs[j])
            da, db_ = samples[i]["seconds"], samples[j]["seconds"]
            close = abs(da - db_) / max(da, db_, 1e-9) < 0.2
            pairs.append({"a": i, "b": j, "similarity": round(sim, 3), "duplicate": bool(sim >= 0.98 and close),
                          "level_diff_db": round(abs(samples[i]["rms_db"] - samples[j]["rms_db"]), 1)})
    med_rms = float(np.median([s["rms_db"] for s in samples]))
    med_snr = float(np.median([s["snr_db"] for s in samples]))
    outliers = [i for i, s in enumerate(samples)
                if abs(s["rms_db"] - med_rms) > 6 or med_snr - s["snr_db"] > 10]
    return {"samples": samples, "pairs": pairs, "outliers": outliers, "median_rms_db": round(med_rms, 1)}


COMMANDS = {"sample_check": cmd_sample_check, "compare_samples": cmd_compare_samples}

core.TOOLS["sample_check"] = {
    "request": lambda in_path, out_path: {"cmd": "sample_check", "audio": in_path},
    "setup": None,
    "streams": False,
    "no_output": True,
}
