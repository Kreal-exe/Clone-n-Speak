"""RVC voice conversion for the pro engines: infer, batch, import, info, fetch, blend (Python 3.9+ syntax).

Run by the app as `<pro python> -s cns_rvc.py <command>` with the Applio root as the working directory; ONE JSON request
line on stdin, events on the cns_proto line protocol on stdout (see the contract table in the pro-engines plan).

Everything that decides whether a request is acceptable (ranges, input planning, model ids, zip and checkpoint checks,
output folders, download rules) is plain Python with no torch, so it is unit-tested on its own. torch, Applio and
soundfile are imported inside the functions that need them.

Untrusted model files: a .pth is a pickle. Nothing here ever unpickles one except torch.load(weights_only=True), which
only builds tensors and plain containers and refuses every other global; a file it refuses is "not a safe voice model
file". A .pth must be a torch zip container without unsafe member names first. The app starts `import`, `info` and
`blend` without network access (sandbox-exec); this script does not depend on that for the pickle rule.
"""
import array
import contextlib
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.parse
import wave
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_engines  # noqa: E402
import cns_net  # noqa: E402
import cns_proto  # noqa: E402

MAX_MODEL_BYTES = 2 << 30
MAX_ZIP_FILES = 20
MAX_BATCH = 200
MAX_RATE = 48000
MAX_SECONDS = 2 * 3600
MIN_SECONDS = 0.1
SILENT_PEAK = 0.001          # -60 dBFS: below this the recording counts as silent
UNREADABLE = "Can't read this audio file. Try WAV, MP3 or M4A."
SILENT = "The recording is silent — nothing to convert"
UNSAFE_MODEL = "This isn’t a safe voice model file"
PTH_SUFFIXES = (".pth",)

F0_METHODS = ("rmvpe", "crepe", "fcpe")
# embedder id -> folder under applio/rvc/models/embedders (the same names Applio's load_embedding uses)
EMBEDDERS = {"contentvec": "contentvec", "japanese-hubert-base": "japanese_hubert_base",
             "chinese-hubert-base": "chinese_hubert_base", "korean-hubert-base": "korean_hubert_base"}
EXPORT_FORMATS = ("WAV", "MP3", "FLAC", "OGG", "M4A")
CLEANUP_MODES = ("off", "light", "speech")
AUDIO_EXTENSIONS = (".wav", ".wave", ".mp3", ".m4a", ".mp4", ".aac", ".flac", ".ogg", ".opus", ".aif", ".aiff",
                    ".caf", ".webm", ".wma", ".mov", ".m4v", ".mkv")


class RvcError(RuntimeError):
    pass


# ----------------------------------------------------------------------------------------------- request validation

def _num(name, value, lo, hi, default, integer=False):
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RvcError("%s must be a number." % name)
    if isinstance(value, float) and not math.isfinite(value):
        raise RvcError("%s must be a number." % name)
    if integer and float(value) != int(value):
        raise RvcError("%s must be a whole number." % name)
    if not lo <= value <= hi:
        raise RvcError("%s must be between %s and %s." % (name, lo, hi))
    return int(value) if integer else float(value)


def _flag(name, value, default=False):
    if value is None:
        return default
    if not isinstance(value, bool):
        raise RvcError("%s must be on or off." % name)
    return value


def _obj(name, value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise RvcError("%s must be an object." % name)
    return value


def validate_infer_request(req):
    """Checks the conversion settings of a request and returns them with defaults filled in (no files touched)."""
    f0 = req.get("f0_method", "rmvpe")
    if f0 not in F0_METHODS:
        raise RvcError("Pitch method must be one of: %s." % ", ".join(F0_METHODS))
    embedder = req.get("embedder", "contentvec")
    if embedder not in EMBEDDERS:
        raise RvcError("Embedder must be one of: %s." % ", ".join(EMBEDDERS))
    fmt = str(req.get("export_format", "WAV")).upper()
    if fmt not in EXPORT_FORMATS:
        raise RvcError("Export format must be one of: %s." % ", ".join(EXPORT_FORMATS))
    formant, auto, clean = _obj("formant", req.get("formant")), _obj("autotune", req.get("autotune")), \
        _obj("cleanup", req.get("cleanup"))
    mode = clean.get("mode", "off")
    if mode not in CLEANUP_MODES:
        raise RvcError("Cleanup mode must be one of: %s." % ", ".join(CLEANUP_MODES))
    return {
        "pitch": _num("Pitch", req.get("pitch"), -24, 24, 0, integer=True),
        "f0_method": f0,
        "index_rate": _num("Index rate", req.get("index_rate"), 0.0, 1.0, 0.3),
        "protect": _num("Protect", req.get("protect"), 0.0, 0.5, 0.33),
        "volume_envelope": _num("Volume envelope", req.get("volume_envelope"), 0.0, 1.0, 1.0),
        "formant": {"on": _flag("Formant shift", formant.get("on")),
                    "qfrency": _num("Formant quefrency", formant.get("qfrency"), 0.1, 16.0, 1.0),
                    "timbre": _num("Formant timbre", formant.get("timbre"), 0.1, 16.0, 1.0)},
        "autotune": {"on": _flag("Autotune", auto.get("on")),
                     "strength": _num("Autotune strength", auto.get("strength"), 0.0, 1.0, 1.0)},
        "cleanup": {"mode": mode, "strength": _num("Cleanup strength", clean.get("strength"), 0.0, 60.0, 12.0)},
        "embedder": embedder,
        "export_format": fmt,
    }


def applio_kwargs(params):
    """The keyword arguments of VoiceConverter.convert_audio for validated params (same set as tools/spikes/infer_bench.py,
    plus formant and cleanup, which Applio reads from **kwargs)."""
    return dict(
        pitch=params["pitch"], index_rate=params["index_rate"], volume_envelope=params["volume_envelope"],
        protect=params["protect"], f0_method=params["f0_method"],
        f0_autotune=params["autotune"]["on"], f0_autotune_strength=params["autotune"]["strength"],
        proposed_pitch=False, proposed_pitch_threshold=155.0, export_format="WAV",
        embedder_model=params["embedder"], embedder_model_custom=None,
        formant_shifting=params["formant"]["on"], formant_qfrency=params["formant"]["qfrency"],
        formant_timbre=params["formant"]["timbre"], sid=0, inference_engine=None, onnx_precision="auto",
        cleanup_mode=params["cleanup"]["mode"], cleanup_strength=params["cleanup"]["strength"])


# ------------------------------------------------------------------------------------------------------ locations

def engine_root(req=None):
    """The engines folder (…/engines): request `engines_root`, else CNS_ENGINES_ROOT, else the parent of the Applio
    working directory (the app starts cns_rvc.py inside <engines>/applio)."""
    if req and req.get("engines_root"):
        return str(req["engines_root"])
    if os.environ.get("CNS_ENGINES_ROOT"):
        return os.environ["CNS_ENGINES_ROOT"]
    cwd = os.getcwd()
    return os.path.dirname(cwd) if os.path.basename(cwd) == "applio" else cwd


def models_root(req=None):
    """Where imported voice models live: request `models_dir`, else CNS_RVC_MODELS, else <app data>/rvc/models, the
    sibling of the engines folder."""
    if req and req.get("models_dir"):
        return str(req["models_dir"])
    if os.environ.get("CNS_RVC_MODELS"):
        return os.environ["CNS_RVC_MODELS"]
    return os.path.join(os.path.dirname(engine_root(req)), "rvc", "models")


def _inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def resolve_model(model, models_dir):
    """(pth path, index path or "", folder) of an installed voice model. `model` is its folder (or just its id); the
    folder must be inside models_dir, whatever symlinks lead there."""
    if not isinstance(model, str) or not model.strip():
        raise RvcError("Choose a voice model first.")
    folder = model if os.sep in model else os.path.join(models_dir, model)
    real = os.path.realpath(os.path.expanduser(folder))
    if not _inside(real, models_dir) or real == os.path.realpath(models_dir):
        raise RvcError("The voice model is outside the app folders.")
    if not os.path.isdir(real):
        raise RvcError("The voice model was not found. Import it again on the Models page.")
    names = sorted(os.listdir(real))
    pths = [n for n in names if n.lower().endswith(".pth") and os.path.isfile(os.path.join(real, n))]
    if not pths:
        raise RvcError("The voice model folder has no .pth file. Import the model again.")
    idx = [n for n in names if n.lower().endswith(".index") and os.path.isfile(os.path.join(real, n))]
    pth = os.path.join(real, pths[0])
    for n in pths:
        if os.path.splitext(n)[0] + ".index" in idx:
            pth = os.path.join(real, n)
            break
    index = os.path.join(real, os.path.splitext(os.path.basename(pth))[0] + ".index")
    return pth, (index if os.path.isfile(index) else (os.path.join(real, idx[0]) if idx else "")), real


def mps_cache_roots():
    """Folders Metal Performance Shaders writes its compiled-graph caches to (per-user temp and cache folders). A sandbox
    that denies writes must allow them or every MPS operation recompiles: Seed-VC then runs 4x slower."""
    roots = []
    for key in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"):
        try:
            base = subprocess.run(["/usr/bin/getconf", key], capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            continue
        if base.startswith("/"):
            roots.append(os.path.join(base, "com.apple.MetalPerformanceShadersGraph"))
    return roots


def embedder_files(applio, embedder):
    folder = os.path.join(applio, "rvc", "models", "embedders", EMBEDDERS[embedder])
    return [os.path.join(folder, "pytorch_model.bin"), os.path.join(folder, "config.json")]


def check_embedder_installed(applio, embedder):
    missing = [p for p in embedder_files(applio, embedder) if not os.path.isfile(p)]
    if missing:
        raise RvcError("The %s embedder is not installed. Open Engines, install it, then try again." % embedder)


def output_dir(req):
    """The folder results go to: `output_dir` (optional) or `outputs_dir`; always inside `outputs_dir`."""
    root = req.get("outputs_dir")
    if not root:
        raise RvcError("Output folder is outside the app folders")
    target = req.get("output_dir") or root
    try:
        return cns_proto.safe_output_dir(target, [root])
    except cns_proto.ProtoError as e:
        raise RvcError(str(e))


def safe_stem(text, fallback="converted"):
    stem = unicodedata.normalize("NFC", os.path.splitext(os.path.basename(str(text)))[0])
    stem = re.sub(r"[^\w.-]+", "_", stem, flags=re.UNICODE).strip("._-")
    return stem[:80] or fallback


def unique_path(folder, stem, ext):
    path = os.path.join(folder, stem + ext)
    n = 2
    while os.path.exists(path):
        path = os.path.join(folder, "%s-%d%s" % (stem, n, ext))
        n += 1
    return path


# -------------------------------------------------------------------------------------------------- audio input plan

def _run_quiet(cmd, timeout=900):
    return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def _tool(name):
    for d in ("/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return None


def probe_audio(path, run=_run_quiet):
    """{'channels','rate','seconds','pcm16'} of an audio file or None when no tool can read it. WAV goes through the
    stdlib; everything else through afinfo, then ffprobe."""
    if path.lower().endswith((".wav", ".wave")):
        try:
            with contextlib.closing(wave.open(path, "rb")) as w:
                rate = w.getframerate()
                return {"channels": w.getnchannels(), "rate": rate,
                        "seconds": w.getnframes() / float(rate) if rate else 0.0, "pcm16": w.getsampwidth() == 2}
        except (wave.Error, EOFError, OSError):
            pass
    afinfo = _tool("afinfo")
    if afinfo:
        try:
            out = run([afinfo, path], 60).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        ch = re.search(r"(\d+) ch,\s+([\d.]+) Hz", out)
        dur = re.search(r"estimated duration:\s+([\d.]+) sec", out)
        if ch and dur:
            return {"channels": int(ch.group(1)), "rate": int(float(ch.group(2))), "seconds": float(dur.group(1)),
                    "pcm16": False}
    ffprobe = _tool("ffprobe")
    if ffprobe:
        try:
            out = run([ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                       "stream=channels,sample_rate:format=duration", "-of", "json", path], 60).stdout
            data = json.loads(out)
            st = data["streams"][0]
            return {"channels": int(st["channels"]), "rate": int(st["sample_rate"]),
                    "seconds": float(data["format"]["duration"]), "pcm16": False}
        except Exception:
            pass
    return None


def plan_prepare_input(path, probe, work_dir, index=0):
    """What to do with an input file before Applio reads it. Returns {'action': 'use'|'convert', 'src', 'dst', 'rate'};
    raises RvcError with the reason for files that cannot work. Applio wants a readable audio file; we hand it mono
    16-bit WAV at no more than 48 kHz (the engine resamples to 16 kHz itself, so more is wasted time)."""
    ext = os.path.splitext(path)[1].lower()
    if ext and ext not in AUDIO_EXTENSIONS:
        raise RvcError("This file type is not supported. Use WAV, MP3, M4A, MP4, FLAC or OGG.")
    dst = os.path.join(work_dir, "input-%d.wav" % index)
    if probe is None:   # no tool could read it: try the converters anyway, they know more formats than the probes
        return {"action": "convert", "src": path, "dst": dst, "rate": None}
    if probe["seconds"] is not None and probe["seconds"] < MIN_SECONDS:
        raise RvcError("The recording is too short (under %.1f s)." % MIN_SECONDS)
    if probe["seconds"] is not None and probe["seconds"] > MAX_SECONDS:
        raise RvcError("The recording is longer than %d hours. Split it and convert the parts." % (MAX_SECONDS // 3600))
    rate = min(probe["rate"], MAX_RATE) if probe.get("rate") else None
    plain = ext in (".wav", ".wave") and probe.get("pcm16") and probe.get("channels") == 1 \
        and probe.get("rate") and probe["rate"] <= MAX_RATE
    return {"action": "use" if plain else "convert", "src": path, "dst": path if plain else dst, "rate": rate}


def convert_commands(src, dst, rate):
    """Converter command lines, preferred first: afconvert (always on macOS), then ffmpeg."""
    cmds = []
    afconvert = _tool("afconvert")
    if afconvert:
        fmt = "LEI16@%d" % rate if rate else "LEI16"
        cmds.append([afconvert, "-f", "WAVE", "-d", fmt, "-c", "1", src, dst])
    ffmpeg = _tool("ffmpeg")
    if ffmpeg:
        cmd = [ffmpeg, "-nostdin", "-y", "-v", "error", "-i", src, "-vn", "-ac", "1"]
        if rate:
            cmd += ["-ar", str(rate)]
        cmds.append(cmd + ["-c:a", "pcm_s16le", dst])
    return cmds


def _wav_header(f):
    """(channels, rate, bits, format code, data offset, data bytes) of a RIFF WAVE file. Own reader because the stdlib's
    wave refuses WAVE_FORMAT_EXTENSIBLE, which afconvert writes for some inputs."""
    head = f.read(12)
    if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
        raise RvcError(UNREADABLE)
    fmt = None
    while True:
        chunk = f.read(8)
        if len(chunk) < 8:
            raise RvcError(UNREADABLE)
        tag, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
        if tag == b"fmt ":
            body = f.read(size + (size & 1))
            if len(body) < 16:
                raise RvcError(UNREADABLE)
            code, ch, rate, _br, _al, bits = struct.unpack("<HHIIHH", body[:16])
            if code == 0xFFFE and len(body) >= 26:
                code = struct.unpack("<H", body[24:26])[0]
            fmt = (code, ch, rate, bits)
        elif tag == b"data":
            if fmt is None:
                raise RvcError(UNREADABLE)
            if size in (0, 0xFFFFFFFF):   # streamed files: the rest of the file
                size = max(0, os.fstat(f.fileno()).st_size - f.tell())
            return fmt[1], fmt[2], fmt[3], fmt[0], f.tell(), size
        else:
            f.seek(size + (size & 1), os.SEEK_CUR)


def wav_stats(path):
    """(peak 0..1, seconds, rate, channels) of a 16-bit PCM WAV, read in blocks."""
    peak = 0
    try:
        with open(path, "rb") as f:
            ch, rate, bits, code, _offset, size = _wav_header(f)
            if code != 1 or bits != 16 or ch < 1 or rate < 1:
                raise RvcError(UNREADABLE)
            n = size // (2 * ch)
            left = size - size % (2 * ch)
            while left > 0:
                block = f.read(min(left, 1 << 20))
                if not block:
                    break
                samples = array.array("h")
                samples.frombytes(block[:len(block) - len(block) % 2])
                if sys.byteorder == "big":
                    samples.byteswap()
                if samples:
                    peak = max(peak, max(samples), -min(samples))
                left -= len(block)
    except (struct.error, OSError):
        raise RvcError(UNREADABLE)
    return min(1.0, peak / 32768.0), n / float(rate), rate, ch


def _convert(src, dst, rate, run):
    for cmd in convert_commands(src, dst, rate):
        try:
            r = run(cmd, 900)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and os.path.isfile(dst) and os.path.getsize(dst) > 44:
            return
    raise RvcError("Can't read this audio file. Try WAV, MP3 or M4A.")


def _stats(path):
    return wav_stats(path)


def prepare_input(path, work_dir, index=0, probe=probe_audio, run=_run_quiet):
    """Returns the path of a mono 16-bit WAV (<= 48 kHz) Applio can read, converting with afconvert/ffmpeg when needed.
    Empty or silent recordings raise RvcError("The recording is silent — nothing to convert")."""
    real = cns_proto.check_input_file(path)
    os.makedirs(work_dir, exist_ok=True)
    plan = plan_prepare_input(real, probe(real), work_dir, index)
    out = plan["dst"]
    if plan["action"] == "convert":
        _convert(real, out, plan["rate"], run)
        if _stats(out)[2] > MAX_RATE:   # the rate was unknown to the probe: bring it down in a second pass
            _convert(out, out + ".2.wav", MAX_RATE, run)
            os.replace(out + ".2.wav", out)
    peak, seconds, _rate, _channels = _stats(out)
    if seconds < MIN_SECONDS:
        raise RvcError("The recording is too short (under %.1f s)." % MIN_SECONDS)
    if peak < SILENT_PEAK:
        raise RvcError(SILENT)
    return out


# ------------------------------------------------------------------------------------------------- model identity

def slug(name, fallback="model"):
    text = unicodedata.normalize("NFKD", str(name or "")).encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()[:40].strip("-")
    return text or fallback


def model_id(name, sha256_hex):
    """slug of the name + the first 8 hex of the .pth's sha256: readable, and two different files never share an id."""
    if not re.fullmatch(r"[0-9a-f]{8,64}", str(sha256_hex)):
        raise RvcError("Bad checksum.")
    return "%s-%s" % (slug(name), sha256_hex[:8])


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


# ------------------------------------------------------------------------------------------- checkpoint safety

def _bad_member(name):
    return (not name or name.startswith(("/", "\\")) or "\\" in name or "\x00" in name or ".." in name.split("/")
            or re.match(r"^[A-Za-z]:", name) is not None)


def check_pth_container(path, max_bytes=MAX_MODEL_BYTES):
    """A .pth must be a torch zip archive whose members have plain relative names. Legacy (non-zip) torch files are pickle
    streams with no structure to check and are refused."""
    try:
        if os.path.getsize(path) > max_bytes:
            raise RvcError("The model file is larger than 2 GB.")
        with open(path, "rb") as f:
            if f.read(4) != b"PK\x03\x04":
                raise RvcError(UNSAFE_MODEL)
        with zipfile.ZipFile(path) as z:
            infos = z.infolist()
            if not any(i.filename.endswith("data.pkl") for i in infos):
                raise RvcError(UNSAFE_MODEL)
            total = 0
            for i in infos:
                if _bad_member(i.filename) or (i.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RvcError(UNSAFE_MODEL)
                total += i.file_size
            if total > max_bytes * 2:
                raise RvcError(UNSAFE_MODEL)
    except (zipfile.BadZipFile, OSError, EOFError, NotImplementedError):
        raise RvcError(UNSAFE_MODEL)
    return path


def load_checkpoint(path):
    """The only way a .pth is read: container checks, then torch.load(weights_only=True)."""
    check_pth_container(path)
    import torch
    try:
        ck = torch.load(path, map_location="cpu", weights_only=True)
    except Exception:   # UnpicklingError, RuntimeError, EOFError, ... every refusal is the same answer
        raise RvcError(UNSAFE_MODEL)
    if not isinstance(ck, dict):
        raise RvcError(UNSAFE_MODEL)
    return ck


def describe_checkpoint(ck, size_bytes, sha256_hex, has_index):
    """The model card fields of a loaded checkpoint dict (needs no torch: it only reads plain values)."""
    weight = ck.get("weight")
    if not isinstance(weight, dict) or "config" not in ck:
        raise RvcError("This isn’t an RVC voice model file")
    version = str(ck.get("version", "v1")).lower()
    if version not in ("v1", "v2"):
        raise RvcError("This isn’t an RVC voice model file")
    sr = str(ck.get("sr", "")).lower().replace("k", "000")
    if not sr.isdigit() or int(sr) not in (32000, 40000, 44100, 48000):
        cfg = ck.get("config")
        sr = str(cfg[-1]) if isinstance(cfg, (list, tuple)) and cfg and str(cfg[-1]).isdigit() else ""
    if not sr.isdigit() or int(sr) not in (32000, 40000, 44100, 48000):
        raise RvcError("This isn’t an RVC voice model file")
    m = re.search(r"(\d+)\s*epoch", str(ck.get("info", "")))
    epochs = int(m.group(1)) if m else None
    f0 = ck.get("f0")
    return {"version": version, "sample_rate": int(sr), "f0": bool(int(f0)) if str(f0).isdigit() or isinstance(f0, (bool, int)) else True,
            "epochs": epochs, "size_bytes": int(size_bytes), "sha256": sha256_hex, "has_index": bool(has_index)}


# ---------------------------------------------------------------------------------------------------- zip import

def extract_model_zip(zip_path, dest, max_total=MAX_MODEL_BYTES, max_files=MAX_ZIP_FILES):
    """Safely unpacks a voice-model archive into dest: only .pth and .index files, flat, under random-free safe names.
    Refuses unsafe member names (anywhere in the archive), symlinks, more than max_files members and more than
    max_total bytes, counted as the bytes really read (a lying header does not help). Returns (pth, index or None)."""
    try:
        z = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError):
        raise RvcError("This isn’t a valid zip file")
    with z:
        infos = [i for i in z.infolist() if not i.is_dir()]
        if len(infos) > max_files:
            raise RvcError("The archive has too many files (more than %d)." % max_files)
        for i in z.infolist():
            if _bad_member(i.filename) or (i.external_attr >> 16) & 0o170000 == 0o120000:
                raise RvcError("The archive has unsafe file names, so nothing was imported.")
        wanted = [i for i in infos if i.filename.lower().endswith((".pth", ".index"))
                  and not os.path.basename(i.filename).startswith("._") and not i.filename.startswith("__MACOSX/")]
        if sum(i.file_size for i in wanted) > max_total:
            raise RvcError("The archive is larger than 2 GB when unpacked.")
        pths = [i for i in wanted if i.filename.lower().endswith(".pth")]
        if not pths:
            raise RvcError("The archive has no voice model (.pth file).")
        if len(pths) > 1:
            raise RvcError("The archive has several models. Import them one at a time.")
        idx = [i for i in wanted if i.filename.lower().endswith(".index")]
        idx.sort(key=lambda i: ("added" not in i.filename.lower(), i.filename))
        os.makedirs(dest, exist_ok=True)
        left = max_total
        out = {}
        for kind, info in (("pth", pths[0]), ("index", idx[0] if idx else None)):
            if info is None:
                continue
            target = os.path.join(dest, "unpacked." + kind)
            with z.open(info) as src, open(target, "wb") as dst:
                while True:
                    block = src.read(1 << 20)
                    if not block:
                        break
                    left -= len(block)
                    if left < 0:
                        raise RvcError("The archive is larger than 2 GB when unpacked.")
                    dst.write(block)
            out[kind] = target
        return out["pth"], out.get("index")


# ----------------------------------------------------------------------------------------------------- the import

def _copy_hashed(src, dst, limit=MAX_MODEL_BYTES):
    h, n = hashlib.sha256(), 0
    with open(src, "rb") as a, open(dst, "wb") as b:
        for block in iter(lambda: a.read(1 << 20), b""):
            n += len(block)
            if n > limit:
                raise RvcError("The model file is larger than 2 GB.")
            h.update(block)
            b.write(block)
    return h.hexdigest(), n


def import_model(models_dir, name, pth=None, index=None, zip_path=None, source_url=None, loader=None, work_dir=None):
    """Copies a voice model into <models_dir>/<id>/ atomically (temporary folder, then rename). The .pth is checked as
    a copy (no swap after the check). Returns {'model_dir', 'info', 'id', 'already'}."""
    loader = loader or load_checkpoint
    os.makedirs(models_dir, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".import-", dir=models_dir)
    try:
        if zip_path:
            src_pth, src_index = extract_model_zip(cns_proto.check_input_file(zip_path), os.path.join(stage, "zip"))
        else:
            if not pth:
                raise RvcError("Choose a .pth voice model file.")
            src_pth, src_index = cns_proto.check_input_file(pth), (cns_proto.check_input_file(index) if index else None)
            if not src_pth.lower().endswith(PTH_SUFFIXES):
                raise RvcError("A voice model file ends with .pth.")
        copy_pth = os.path.join(stage, "model.pth")
        digest, size = _copy_hashed(src_pth, copy_pth)
        ck = loader(copy_pth)
        has_index = bool(src_index)
        info = describe_checkpoint(ck, size, digest, has_index)
        mid = model_id(name or os.path.splitext(os.path.basename(src_pth))[0], digest)
        final = os.path.join(models_dir, mid)
        if os.path.isdir(final) and os.path.isfile(os.path.join(final, "meta.json")):
            return {"model_dir": final, "info": info, "id": mid, "already": True}
        base = slug(name or os.path.splitext(os.path.basename(src_pth))[0])
        pack = os.path.join(stage, "pack")
        os.makedirs(pack)
        os.replace(copy_pth, os.path.join(pack, base + ".pth"))
        if src_index:
            if os.path.getsize(src_index) > MAX_MODEL_BYTES:
                raise RvcError("The index file is larger than 2 GB.")
            shutil.copyfile(src_index, os.path.join(pack, base + ".index"))
        meta = {"id": mid, "name": str(name or base)[:120], "sha256": digest, "source_url": source_url,
                "imported_at": int(time.time()), "info": info}
        with open(os.path.join(pack, "meta.json"), "w") as f:
            json.dump(meta, f, ensure_ascii=False, indent=1)
        if os.path.exists(final):
            shutil.rmtree(final)   # a half-made folder from an older crash (no meta.json)
        os.rename(pack, final)
        return {"model_dir": final, "info": info, "id": mid, "already": False}
    finally:
        shutil.rmtree(stage, ignore_errors=True)


# --------------------------------------------------------------------------------------------------------- fetch

def normalize_model_url(url):
    """The https URL to download: Hugging Face 'blob' pages become 'resolve' (the file itself)."""
    if not isinstance(url, str):
        raise RvcError("Paste a link to a voice model.")
    parts = urllib.parse.urlsplit(url.strip())
    if parts.scheme.lower() != "https" or not parts.hostname:
        raise RvcError("Only secure https:// links can be downloaded.")
    path = parts.path
    if parts.hostname.lower() in ("huggingface.co", "www.huggingface.co", "hf.co") and "/blob/" in path:
        path = path.replace("/blob/", "/resolve/", 1)
    return urllib.parse.urlunsplit(("https", parts.netloc, path, parts.query, ""))


def fetch_model(url, work_dir, emit_fn=None, opener=None, max_bytes=MAX_MODEL_BYTES, download=None):
    """Downloads a model (.pth or .zip) to work_dir/fetch through cns_engines.download (https only, Range resume into a
    .part, size limit, https-only redirects). Returns (path, kind) where kind is 'pth' or 'zip'."""
    url = normalize_model_url(url)
    ext = os.path.splitext(urllib.parse.urlsplit(url).path)[1].lower()
    if ext not in (".pth", ".zip"):
        raise RvcError("The link must point to a .pth or .zip file.")
    cns_net.require_online("model_download")
    folder = os.path.join(work_dir, "fetch")
    os.makedirs(folder, exist_ok=True)
    dest = os.path.join(folder, hashlib.sha256(url.encode()).hexdigest()[:16] + ext)
    download = download or cns_engines.download
    try:
        download(url, dest, None, None, emit_fn, opener, max_bytes=max_bytes)
    except cns_engines.EngineError as e:
        raise RvcError(str(e))
    return dest, ext[1:]


# --------------------------------------------------------------------------------------------------------- batch

def run_batch(inputs, convert_one, emit_fn=None):
    """Converts every input with convert_one(path, index) -> output path. A file that fails is recorded and the rest go
    on. Returns (outputs, failed[{'input','error'}])."""
    outputs, failed = [], []
    total = len(inputs)
    for n, path in enumerate(inputs):
        try:
            outputs.append(convert_one(path, n))
        except (RvcError, cns_proto.ProtoError, cns_engines.EngineError) as e:
            failed.append({"input": path, "error": str(e)})
        except Exception as e:   # one bad file must not stop the other 199
            failed.append({"input": path, "error": "%s: %s" % (type(e).__name__, e)})
        if emit_fn:
            emit_fn("progress", value=(n + 1) / float(total))
    return outputs, failed


# ------------------------------------------------------------------------------------------------- engine (torch)

@contextlib.contextmanager
def heartbeat(label, every=15.0):
    """Emits a status line every `every` seconds while a long blocking call runs (the app's watchdog expects events)."""
    stop = threading.Event()
    t0 = time.time()

    def beat():
        while not stop.wait(every):
            cns_proto.status("%s… %d s" % (label, time.time() - t0))

    th = threading.Thread(target=beat, daemon=True)
    th.start()
    try:
        yield
    finally:
        stop.set()


def peak_gb():
    import resource
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 2)   # bytes on macOS


def _prepare_process(req):
    """Environment of the heavy process: offline, caches and Applio's settings inside the job folder."""
    work = req.get("work_dir") or tempfile.mkdtemp(prefix="cns-rvc-")
    os.makedirs(work, exist_ok=True)
    for k, v in (("PYTORCH_ENABLE_MPS_FALLBACK", "1"), ("HF_HUB_OFFLINE", "1"), ("TRANSFORMERS_OFFLINE", "1"),
                 ("PYTHONDONTWRITEBYTECODE", "1")):
        os.environ.setdefault(k, v)
    os.environ.setdefault("NUMBA_CACHE_DIR", os.path.join(work, "numba-cache"))   # librosa caches compiled code
    os.environ["APPLIO_CONFIG_DIR"] = os.path.join(work, "applio-config")
    os.environ["APPLIO_LOGS_DIR"] = os.path.join(work, "logs")
    os.makedirs(os.environ["APPLIO_LOGS_DIR"], exist_ok=True)
    applio = os.getcwd()
    if not os.path.isfile(os.path.join(applio, "rvc", "infer", "infer.py")):
        raise RvcError("The voice engine is not installed. Open Engines and press Install.")
    sys.path.insert(0, applio)
    return work, applio


class Converter:
    """One loaded Applio VoiceConverter reused for every file of a run (the warm path: 1.3 s instead of 3-4 s)."""

    def __init__(self):
        from rvc.infer.infer import VoiceConverter   # imported here: needs torch and the Applio working directory
        self.vc = VoiceConverter()

    @property
    def device(self):
        return str(self.vc.config.device)

    def convert(self, wav_in, wav_out, pth, index, params):
        self.vc.convert_audio(audio_input_path=wav_in, audio_output_path=wav_out, model_path=pth,
                              index_path=index or "", **applio_kwargs(params))
        return wav_out

    @property
    def sample_rate(self):
        return int(self.vc.tgt_sr or 0)


def final_output(produced_wav, params, outdir, stem, work):
    """Moves the result into the outputs folder in the chosen format (Applio writes WAV, plus the converted file)."""
    ext = "." + params["export_format"].lower()
    src = produced_wav if ext == ".wav" else os.path.splitext(produced_wav)[0] + ext
    if not os.path.isfile(src):
        raise RvcError("The conversion produced no audio. Try again, or pick another voice model.")
    dest = unique_path(outdir, stem, ext)
    shutil.move(src, dest)
    return dest


def _audio_seconds(path):
    try:
        import soundfile
        return round(soundfile.info(path).duration, 2)
    except Exception:
        return None


def _convert_files(req, inputs, params, emit_fn):
    work, applio = _prepare_process(req)
    check_embedder_installed(applio, params["embedder"])
    pth, index, folder = resolve_model(req.get("model"), models_root(req))
    if params["index_rate"] == 0:
        index = ""
    outdir = output_dir(req)
    model_name = safe_stem(os.path.basename(folder))
    cns_proto.status("Loading the voice engine…")
    conv = Converter()
    cns_proto.progress(0.05)
    t_total = time.time()

    def one(path, n):
        wav = prepare_input(path, os.path.join(work, "in"), n)
        produced = os.path.join(work, "out", "%s-%d.wav" % (model_name, n))
        os.makedirs(os.path.dirname(produced), exist_ok=True)
        with heartbeat("Converting"):
            conv.convert(wav, produced, pth, index, params)
        return final_output(produced, params, outdir, "%s_%s" % (safe_stem(path), model_name), work)

    return conv, one, t_total


def cmd_infer(req):
    params = validate_infer_request(req)
    if not req.get("input"):
        raise RvcError("Choose a recording to convert.")
    conv, one, t0 = _convert_files(req, [req["input"]], params, cns_proto.emit)
    t = time.time()
    out = one(req["input"], 0)
    cns_proto.result(outputs=[out], seconds=round(time.time() - t, 2), total_seconds=round(time.time() - t0, 2),
                     device=conv.device, sample_rate=conv.sample_rate, duration=_audio_seconds(out),
                     peak_gb=peak_gb())


def cmd_batch(req):
    params = validate_infer_request(req)
    inputs = req.get("inputs")
    if not isinstance(inputs, list) or not inputs or not all(isinstance(p, str) for p in inputs):
        raise RvcError("Choose the recordings to convert.")
    if len(inputs) > MAX_BATCH:
        raise RvcError("Convert at most %d files at a time." % MAX_BATCH)
    conv, one, t0 = _convert_files(req, inputs, params, cns_proto.emit)
    cns_proto.status("Converting %d files…" % len(inputs))
    outputs, failed = run_batch(inputs, one, lambda ev, **kw: cns_proto.emit(ev, **kw))
    if not outputs:
        raise RvcError("None of the %d files could be converted: %s" % (len(inputs), failed[0]["error"]))
    cns_proto.result(outputs=outputs, failed=failed, seconds=round(time.time() - t0, 2), device=conv.device,
                     peak_gb=peak_gb())


def cmd_info(req):
    models = models_root(req)
    if req.get("model"):
        pth, index, _ = resolve_model(req["model"], models)
    else:
        pth, index = cns_proto.check_input_file(req.get("pth") or ""), ""
    ck = load_checkpoint(pth)
    info = describe_checkpoint(ck, os.path.getsize(pth), file_sha256(pth), bool(index))
    cns_proto.result(**info)


def cmd_import(req):
    models = models_root(req)
    res = import_model(models, req.get("name"), pth=req.get("pth"), index=req.get("index"), zip_path=req.get("zip"),
                       source_url=req.get("source_url"))
    cns_proto.result(model_dir=res["model_dir"], info=res["info"], id=res["id"], already=res["already"])


def cmd_fetch(req):
    work = req.get("work_dir") or tempfile.mkdtemp(prefix="cns-rvc-")
    cns_proto.status("Downloading the voice model…")
    with heartbeat("Downloading", 10.0):   # the size is unknown up front, so there is no percentage to report
        path, kind = fetch_model(req.get("url"), work, lambda ev, **kw: cns_proto.emit(ev, **kw))
    name = req.get("name") or os.path.splitext(os.path.basename(urllib.parse.urlsplit(req["url"]).path))[0]
    cns_proto.status("Checking the model…")
    res = import_model(models_root(req), name, pth=path if kind == "pth" else None,
                       zip_path=path if kind == "zip" else None, source_url=normalize_model_url(req["url"]))
    cns_proto.result(model_dir=res["model_dir"], info=res["info"], id=res["id"], already=res["already"])


def cmd_blend(req):
    ratio = _num("Ratio", req.get("ratio"), 0.0, 1.0, None)
    if ratio is None:
        raise RvcError("Set how much of each voice to mix.")
    name = str(req.get("name") or "").strip()
    if not name:
        raise RvcError("Name the new voice.")
    models = models_root(req)
    a, _, _ = resolve_model(req.get("model_a"), models)
    b, _, _ = resolve_model(req.get("model_b"), models)
    work, _applio = _prepare_process(req)
    from rvc.train.process.model_blender import model_blender   # weights_only=True inside
    tmp_name = "cns-blend-%d" % os.getpid()
    cns_proto.status("Blending the voices…")
    res = model_blender(tmp_name, a, b, ratio)
    if not (isinstance(res, tuple) and len(res) == 2 and os.path.isfile(res[1])):
        raise RvcError(str(res) if res else "The voices could not be blended.")
    try:
        # the blended file has no index: indexes are not mixed
        out = import_model(models, name, pth=res[1])
    finally:
        with contextlib.suppress(OSError):
            os.remove(res[1])
    cns_proto.result(model_dir=out["model_dir"], info=out["info"], id=out["id"], already=out["already"])


COMMANDS = {"infer": cmd_infer, "batch": cmd_batch, "info": cmd_info, "import": cmd_import, "fetch": cmd_fetch,
            "blend": cmd_blend}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cns_proto.install_stdout_guard()
    if len(argv) != 1 or argv[0] not in COMMANDS:
        cns_proto.fail("Usage: cns_rvc.py %s" % "|".join(COMMANDS))
        return 2
    try:
        req = cns_proto.read_request()
        COMMANDS[argv[0]](req)
    except (RvcError, cns_proto.ProtoError, cns_engines.EngineError, cns_net.OfflineError) as e:
        cns_proto.fail(str(e))
        return 1
    except Exception as e:
        import traceback
        traceback.print_exc()
        cns_proto.fail("The conversion failed (%s). Close other apps and try again." % type(e).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
