"""Music removal ("keep only the voice") for Clone'n'Speak 2.0: an MDX-Net ONNX model on onnxruntime, no PyTorch.

The engine is optional. `onnxruntime` is installed on demand by the app (OVRuntime installOptionalPackages) and the
model (Kim_Vocal_2, ~67 MB) is downloaded on demand into <support>/models/separation. Both are checked before any work
starts, and a missing one raises EngineMissing with the action to take. `onnxruntime` is imported only inside
_open_session; numpy / scipy are imported inside functions, so importing this module is cheap and safe everywhere.

The signal path (ported from tools/spikes/ort_vocals.py, spike row 11): stereo 44.1 kHz audio is cut into chunks of
CHUNK = hop * (dim_t - 1) samples that overlap by n_fft; each chunk goes through an STFT (n_fft 7680, hop 1024), the
network, a compensation gain and an inverse STFT; only the centre GEN = CHUNK - n_fft samples of every chunk are kept,
because the edges carry STFT boundary artifacts. CPU only: CoreML was not faster on the spike and needed more memory.

Commands: sep_status, sep_install_model, sep_remove_model, sep_vocals. Python 3.9 compatible.
"""
import hashlib
import importlib
import importlib.util
import os
import sys
import time
import urllib.error
import urllib.request

import cns_core as core

SAMPLE_RATE = 44100

CATALOG = [{
    "id": "kim_vocal_2",
    "title": "Voice extractor (MDX-Net)",
    "file": "Kim_Vocal_2.onnx",
    "url": "https://huggingface.co/diarizeapp/uvr-kim-vocal-2/resolve/"
           "e24eb91da6035652bf05d6d721bf83da24fe782c/Kim_Vocal_2.onnx",
    "sha256": "ce74ef3b6a6024ce44211a07be9cf8bc6d87728cc852a68ab34eb8e58cde9c8b",
    "size": 66759214,
    # The weight author has not published a license (docs/superpowers/notes/2026-11-09-model-licenses.md); this is
    # the tag of the re-upload we download from. Shipping it was an explicit decision of the project owner.
    "license": "Apache-2.0 (tag of the Hugging Face re-upload; the original author gave no license)",
    "license_url": "https://huggingface.co/diarizeapp/uvr-kim-vocal-2",
    "backend": "mdx",
    "params": {"n_fft": 7680, "dim_f": 3072, "dim_t": 256, "hop": 1024, "compensate": 1.009, "sr": 44100},
}]

ENGINE_HINT = "Download the music-removal engine in Separation (~140 MB)"


class EngineMissing(core.AudioInputError, RuntimeError):
    """onnxruntime or the model is not installed. `str(e)` names the action; `code` is "engine_missing"."""

    def __init__(self, message=ENGINE_HINT + "."):
        core.AudioInputError.__init__(self, "engine_missing", message)


class ModelDownloadError(RuntimeError):
    """The model could not be downloaded or failed its checksum."""


# --------------------------------------------------------------------------
# STFT / ISTFT (scipy.fft)
# --------------------------------------------------------------------------
_WINDOWS = {}
_NORMS = {}


def _window(n_fft):
    import numpy as np
    w = _WINDOWS.get(n_fft)
    if w is None:
        w = np.hanning(n_fft + 1)[:-1].astype(np.float32)  # periodic Hann, as torch.hann_window
        _WINDOWS[n_fft] = w
    return w


def stft(x, n_fft, hop):
    """x: (T,) -> (n_fft // 2 + 1, frames) complex64; centred, reflect padding (as torch.stft center=True)."""
    import numpy as np
    from scipy import fft as sfft
    x = np.pad(np.asarray(x, dtype=np.float32), (n_fft // 2, n_fft // 2), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    return sfft.rfft(frames * _window(n_fft), axis=1).T


def _window_norm(n_fft, hop, frames):
    import numpy as np
    key = (n_fft, hop, frames)
    norm = _NORMS.get(key)
    if norm is None:
        norm = np.zeros(n_fft + hop * (frames - 1), dtype=np.float32)
        w2 = _window(n_fft) ** 2
        for i in range(frames):
            norm[i * hop:i * hop + n_fft] += w2
        _NORMS.clear()
        _NORMS[key] = norm
    return norm


def istft(spec, n_fft, hop, length):
    """Inverse of stft(): spec (n_fft // 2 + 1, frames) -> (length,) float32 (weighted overlap-add)."""
    import numpy as np
    from scipy import fft as sfft
    frames = sfft.irfft(spec.T, n=n_fft, axis=1).astype(np.float32, copy=False) * _window(n_fft)
    count = frames.shape[0]
    out = np.zeros(n_fft + hop * (count - 1), dtype=np.float32)
    for i in range(count):
        out[i * hop:i * hop + n_fft] += frames[i]
    out /= np.maximum(_window_norm(n_fft, hop, count), 1e-8)
    return out[n_fft // 2:n_fft // 2 + length]


# --------------------------------------------------------------------------
# Separation
# --------------------------------------------------------------------------
def separate(wav_stereo_44k, session, params, progress=None):
    """wav_stereo_44k: (2, n) float32 at 44.1 kHz. session: an onnxruntime-like object (get_inputs(), run()).
    Returns the vocals, (2, n) float32. progress(fraction) is called after every chunk. Memory stays bounded by the
    chunk size plus the output buffer, whatever the length of the input."""
    import numpy as np
    n_fft, hop = int(params["n_fft"]), int(params["hop"])
    dim_f, dim_t = int(params["dim_f"]), int(params["dim_t"])
    comp = float(params.get("compensate", 1.0))
    chunk = hop * (dim_t - 1)
    trim = n_fft // 2
    gen = chunk - n_fft
    bins = n_fft // 2 + 1
    mix = np.asarray(wav_stereo_44k, dtype=np.float32)
    if mix.ndim != 2 or mix.shape[0] != 2:
        raise ValueError("separate() takes a stereo array of shape (2, n)")
    n = mix.shape[1]
    out = np.zeros((2, n), dtype=np.float32)
    if n == 0:
        return out
    pad = (-n) % gen
    mix_p = np.zeros((2, trim + n + pad + trim), dtype=np.float32)
    mix_p[:, trim:trim + n] = mix
    name = session.get_inputs()[0].name
    starts = list(range(0, n + pad, gen))
    for k, i in enumerate(starts):
        block = mix_p[:, i:i + chunk]
        x = np.empty((4, dim_f, dim_t), dtype=np.float32)
        for c in range(2):
            spec = stft(block[c], n_fft, hop)[:dim_f]
            x[2 * c] = spec.real
            x[2 * c + 1] = spec.imag
        y = np.asarray(session.run(None, {name: x[None]})[0], dtype=np.float32)[0] * comp  # (4, dim_f, dim_t)
        full = np.zeros((4, bins, dim_t), dtype=np.float32)
        full[:, :dim_f] = y
        for c in range(2):
            rec = istft(full[2 * c] + 1j * full[2 * c + 1], n_fft, hop, chunk)[trim:trim + gen]
            end = min(n, i + gen)
            out[c, i:end] = rec[:end - i]
        if progress is not None:
            progress((k + 1) / float(len(starts)))
    return out


# --------------------------------------------------------------------------
# Model files
# --------------------------------------------------------------------------
def _entry(model_id):
    if not model_id:
        return CATALOG[0]
    for e in CATALOG:
        if e["id"] == model_id:
            return e
    raise core.AudioInputError("bad_param", "This separation model is unknown. Choose one from the list.")


def _models_dir(req=None):
    d = (req or {}).get("dir") or os.environ.get("CNS_SEPARATION_DIR")
    if d:
        return d
    base = os.environ.get("OV_DATA_DIR") or os.path.expanduser("~/Library/Application Support/Clone'n'Speak")
    return os.path.join(base, "models", "separation")


def _model_path(entry, directory):
    return os.path.join(directory, entry["file"])


def _model_ready(entry, directory):
    """A model counts as installed only as the final file with the exact size; a .part never does."""
    try:
        return os.path.getsize(_model_path(entry, directory)) == entry["size"]
    except OSError:
        return False


def _onnxruntime_present():
    importlib.invalidate_caches()  # the app may have installed it while this worker was running
    try:
        return importlib.util.find_spec("onnxruntime") is not None
    except (ImportError, ValueError):
        return False


_VERIFIED = {}  # path -> (mtime_ns, size) of a file whose SHA-256 was checked in this process


def _verify_model(entry, path):
    """Re-checks the SHA-256 the first time a model file is used in this process (or after it changed on disk)."""
    st = os.stat(path)
    sig = (st.st_mtime_ns, st.st_size)
    if _VERIFIED.get(path) == sig:
        return
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != entry["sha256"]:
        _VERIFIED.pop(path, None)
        _silent_remove(path)
        raise EngineMissing("The voice extractor file failed its checksum test and was deleted. "
                            + ENGINE_HINT + " again.")
    _VERIFIED[path] = sig


def _prepare(entry, directory):
    """Checks that the engine and the model are there; returns the model path. Raises EngineMissing."""
    if not _onnxruntime_present() or not _model_ready(entry, directory):
        raise EngineMissing()
    path = _model_path(entry, directory)
    _verify_model(entry, path)
    return path


def _open_session(path):
    import onnxruntime as ort  # lazy: ~76 MB of libraries only the people who remove music load
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    return ort.InferenceSession(path, sess_options=opts, providers=["CPUExecutionProvider"])


class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    """Follows redirects (Hugging Face sends the file to a CDN) but never from https down to anything else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise urllib.error.URLError("redirect to a non-HTTPS address refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open_url(url):
    import ssl
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except Exception:
        ctx = ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), _HttpsOnlyRedirect())
    return opener.open(urllib.request.Request(url, headers={"User-Agent": "Clone-n-Speak"}), timeout=60)


def _download(entry, directory, progress=None):
    """Downloads the model to <file>.part, checks size and SHA-256, then moves it into place. A mismatch deletes the
    file and raises ModelDownloadError naming the checksum."""
    url = entry["url"]
    if not url.startswith("https://"):
        raise ModelDownloadError("The model address is not a secure (HTTPS) link, so it was not downloaded.")
    os.makedirs(directory, exist_ok=True)
    final = _model_path(entry, directory)
    part = final + ".part"
    digest = hashlib.sha256()
    done = 0
    try:
        with _open_url(url) as resp, open(part, "wb") as f:
            while True:
                block = resp.read(1 << 20)
                if not block:
                    break
                done += len(block)
                if done > entry["size"]:  # more than the catalog promises: stop before filling the disk
                    raise ModelDownloadError("The download is larger than expected, so it was stopped and deleted "
                                             "(checksum cannot match). Try again later.")
                f.write(block)
                digest.update(block)
                if progress is not None:
                    progress(min(1.0, done / float(entry["size"])))
        if done != entry["size"] or digest.hexdigest() != entry["sha256"]:
            raise ModelDownloadError("The downloaded model failed the checksum test and was deleted. "
                                     "Try the download again.")
        os.replace(part, final)
    except ModelDownloadError:
        _silent_remove(part)
        raise
    except OSError as e:  # URLError, timeouts and disk errors are all OSErrors
        _silent_remove(part)
        raise ModelDownloadError("The model could not be downloaded (%s). Check the internet connection and "
                                 "free disk space, then try again." % (getattr(e, "reason", None) or e))
    except BaseException:
        _silent_remove(part)
        raise


def _silent_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


# --------------------------------------------------------------------------
# Running the model
# --------------------------------------------------------------------------
def _run_model(model_path, mix44, entry, progress=None):
    """Frees the speech models, opens one session for this run, separates, releases the session."""
    import gc
    core.free_models()
    session = _open_session(model_path)
    try:
        return separate(mix44, session, entry["params"], progress)
    finally:
        del session
        gc.collect()


def _to_stereo_44k(wav, rate):
    """(n,) or (n, ch) at `rate` -> (2, m) float32 at 44.1 kHz."""
    import numpy as np
    x = np.asarray(wav, dtype=np.float32)
    if x.ndim == 2:
        if x.shape[1] == 2:
            pass
        elif x.shape[1] == 1:
            x = x[:, 0]
        else:
            x = x.mean(axis=1)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    x = core.resample(x, rate, SAMPLE_RATE)
    return np.ascontiguousarray(x.T)


def _from_stereo_44k(y, rate, channels, length):
    """(2, m) at 44.1 kHz -> the input's rate and channel count (1 or 2), exactly `length` samples."""
    import numpy as np
    x = y.T
    x = core.resample(x, SAMPLE_RATE, rate)
    if channels == 1:
        x = x.mean(axis=1)
    if x.shape[0] < length:
        x = np.concatenate([x, np.zeros((length - x.shape[0],) + x.shape[1:], dtype=np.float32)])
    return np.ascontiguousarray(x[:length])


def _check_finite(x):
    import numpy as np
    if not np.isfinite(x).all():
        raise core.AudioInputError("unsupported", "The separation produced invalid audio for this file. "
                                                  "Try another recording or cut it into shorter parts.")


def _limit(x):
    """A stem that overshoots full scale is scaled down as a whole instead of being clipped."""
    import numpy as np
    peak = float(np.abs(x).max()) if x.size else 0.0
    return x * (0.99 / peak) if peak > 1.0 else x


def sep_vocals(req):
    """req: audio, out, stem ("vocals" | "music"), id?, dir?. Writes the stem at the rate of the input: mono stays
    mono, everything else (stereo and multichannel, which is mixed down first) comes out as stereo. -> {"path", "seconds", "stem"}."""
    stem = req.get("stem", "vocals")
    if stem not in ("vocals", "music"):
        raise core.AudioInputError("bad_param", 'Choose what to keep: "vocals" or "music".')
    entry = _entry(req.get("id"))
    model_path = _prepare(entry, _models_dir(req))
    wav, rate = core.read_audio(req["audio"], mono=False, allow_silent=False)
    channels = 1 if wav.ndim == 1 else min(2, wav.shape[1])
    length = wav.shape[0]
    mix44 = _to_stereo_44k(wav, rate)
    vocals = _run_model(model_path, mix44, entry, core.emit_progress)
    result = vocals if stem == "vocals" else mix44 - vocals  # the music is whatever the voice leaves, at 44.1 kHz
    _check_finite(result)
    out = _limit(_from_stereo_44k(result, rate, channels, length))
    seconds = core.write_audio(req["out"], out, rate, subtype="pcm24")
    return {"path": req["out"], "seconds": seconds, "stem": stem}


def sep_status(req):
    entry = _entry((req or {}).get("id"))
    directory = _models_dir(req)
    info = {k: v for k, v in entry.items() if k != "url"}
    return {"onnxruntime": _onnxruntime_present(), "model_ready": _model_ready(entry, directory),
            "model": info, "size": entry["size"]}


def sep_install_model(req):
    entry = _entry((req or {}).get("id"))
    directory = _models_dir(req)
    if not _model_ready(entry, directory):
        core.emit_status("Downloading the voice extractor…")
        _download(entry, directory, core.emit_progress)
    return {"model_ready": True}


def sep_remove_model(req):
    entry = _entry((req or {}).get("id"))
    path = _model_path(entry, _models_dir(req))
    _silent_remove(path)
    _silent_remove(path + ".part")
    return {"model_ready": False}


def _pre_enhance(req, wav, sr):
    """req["mode"] == "music": clean the sample from music first; the voice (mono, `sr`) replaces the wav."""
    if req.get("mode") != "music":
        return wav
    entry = _entry(req.get("separation_model"))
    model_path = _prepare(entry, _models_dir(req))
    mix44 = _to_stereo_44k(wav, sr)
    vocals = _run_model(model_path, mix44, entry, core.emit_progress)
    _check_finite(vocals)
    return _from_stereo_44k(vocals, sr, 1, len(wav))


COMMANDS = {
    "sep_status": sep_status,
    "sep_install_model": sep_install_model,
    "sep_remove_model": sep_remove_model,
    "sep_vocals": sep_vocals,
}

core.PRE_ENHANCE.append(_pre_enhance)


def _setup_stub(tmpdir):
    """Test registry setup: a stand-in session (the voice is half the mix), no onnxruntime and no model needed."""
    module = sys.modules[__name__]
    saved = (module._prepare, module._open_session)

    class _Input:
        name = "input"

    class _Stub:
        def get_inputs(self):
            return [_Input()]

        def run(self, outputs, feed):
            return [feed["input"] * 0.5]

    module._prepare = lambda entry, directory: "stub"
    module._open_session = lambda path: _Stub()

    def cleanup():
        module._prepare, module._open_session = saved
    return cleanup


core.TOOLS["sep_vocals"] = {
    "request": lambda src, dst: {"cmd": "sep_vocals", "audio": src, "out": dst, "stem": "vocals"},
    "setup": _setup_stub,
    "streams": False,
}
