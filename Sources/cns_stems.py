"""Full stem separation for the pro environment (audio-separator 0.45.0): `separate` and `fetch-model`.

    python cns_stems.py separate     request JSON on stdin; events on stdout (see cns_proto)
    python cns_stems.py fetch-model  --root <engines> --model <id>   (downloads the pinned files, sha256 checked)

Request (separate): input, model (catalog id), stems (all|vocals|instrumental|<stem>), output_format (wav|flac|mp3),
work_dir, outputs_dir, chunk_s (optional, 10..900, default 300). Result: outputs[] (one file per stem), model, seconds.

Models are never downloaded by audio-separator: fetch-model/cns_engines.install put the pinned files in
<engines>/stems/<id>/ (url + sha256 from cns_pins.STEMS), and the Separator is pointed at that folder. Long input is cut
into chunks that overlap by 2 s and are cross-faded back together, so memory is bounded by the chunk, not the song.
No heavy imports at module load (audio-separator, numpy and soundfile are imported inside functions).
"""
import argparse
import os
import re
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_engines  # noqa: E402
import cns_pins as pins  # noqa: E402
import cns_proto  # noqa: E402
import cns_stems_catalog as catalog  # noqa: E402

FORMATS = ("wav", "flac", "mp3")
MIN_SECONDS = 1.0
SILENCE_PEAK = 1e-4
CHUNK_DEFAULT_S = 300
CHUNK_MIN_S = 10
CHUNK_MAX_S = 900
OVERLAP_S = 2.0

# audio-separator names its files "<input>_(<Stem>)_<model>.<ext>"; the label is mapped to our stem names.
STEM_LABELS = {
    "vocals": "vocals", "instrumental": "instrumental", "drums": "drums", "bass": "bass", "other": "other",
    "guitar": "guitar", "piano": "piano", "no reverb": "dry", "noreverb": "dry", "dry": "dry", "reverb": "reverb",
    "no echo": "dry",
}
_LABEL = re.compile(r"_\(([^)]+)\)")


class StemError(cns_proto.ProtoError):
    pass


def stem_name(filename):
    """'song_(Vocals)_Kim_Vocal_2.wav' -> 'vocals'; None when the file name carries no known stem label."""
    found = _LABEL.findall(os.path.basename(filename))
    for label in reversed(found):
        name = STEM_LABELS.get(label.strip().lower())
        if name:
            return name
    return None


def wanted_stems(entry, stems):
    """The stem names to write for a request. 'instrumental' is derived (the sum of everything but vocals) when the
    model has no instrumental output of its own."""
    outputs = list(entry["outputs"])
    derivable = "vocals" in outputs and "instrumental" not in outputs
    allowed = outputs + (["instrumental"] if derivable else [])
    if stems == "all":
        return allowed
    if stems not in allowed:
        raise StemError("This model cannot give '%s'. Choose one of: %s." % (stems, ", ".join(allowed)))
    return [stems]


def validate_request(req, roots=None):
    """Checks a separate request before anything heavy happens; returns a clean dict."""
    entry = catalog.get(str(req.get("model") or catalog.DEFAULT_ID))
    if entry is None:
        raise StemError("Unknown separation model: %s." % req.get("model"))
    fmt = str(req.get("output_format") or "wav").lower()
    if fmt not in FORMATS:
        raise StemError("Unsupported output format '%s'. Use %s." % (fmt, ", ".join(FORMATS)))
    path = req.get("input")
    if not path:
        raise StemError("No input file given.")
    real = cns_proto.check_input_file(path)
    chunk_s = req.get("chunk_s") or CHUNK_DEFAULT_S
    try:
        chunk_s = float(chunk_s)
    except (TypeError, ValueError):
        raise StemError("chunk_s must be a number of seconds.")
    if not CHUNK_MIN_S <= chunk_s <= CHUNK_MAX_S:
        raise StemError("chunk_s must be between %d and %d seconds." % (CHUNK_MIN_S, CHUNK_MAX_S))
    stems = wanted_stems(entry, str(req.get("stems") or "all").lower())
    out = {"input": real, "entry": entry, "format": fmt, "stems": stems, "chunk_s": chunk_s}
    if roots is not None:
        out["outputs_dir"] = cns_proto.safe_output_dir(req.get("outputs_dir") or "", roots)
    return out


def check_audio(frames, samplerate, peak):
    """Short and silent files fail with a plain message before the model is loaded."""
    if samplerate <= 0 or frames <= 0:
        raise StemError("This file has no audio.")
    if frames / float(samplerate) < MIN_SECONDS:
        raise StemError("This audio is shorter than 1 second. Use a longer recording.")
    if peak < SILENCE_PEAK:
        raise StemError("This audio is silent, so there is nothing to separate.")


def plan_chunks(total_frames, samplerate, chunk_s=CHUNK_DEFAULT_S, overlap_s=OVERLAP_S):
    """[(start, end)] frame ranges that cover the file; neighbours overlap by overlap_s. No range is longer than
    chunk_s (+ nothing), so the work per chunk, and the memory it needs, does not grow with the file."""
    chunk = max(int(chunk_s * samplerate), 1)
    ov = min(int(overlap_s * samplerate), chunk // 2)
    if total_frames <= chunk:
        return [(0, total_frames)]
    out, start = [], 0
    while True:
        end = min(start + chunk, total_frames)
        out.append((start, end))
        if end >= total_frames:
            return out
        start = end - ov


# ------------------------------------------------------------------------------------------------------------ audio io

class SoundFileIO:
    """The real audio access: soundfile + numpy, imported on first use."""

    def __init__(self):
        import numpy as np
        import soundfile as sf
        self.np, self.sf = np, sf

    def info(self, path):
        i = self.sf.info(path)
        return i.frames, i.samplerate, i.channels

    def peak(self, path):
        peak = 0.0
        with self.sf.SoundFile(path) as f:
            while True:
                block = f.read(1 << 20, dtype="float32")
                if not len(block):
                    return peak
                peak = max(peak, float(abs(block).max()))

    def read(self, path, start=0, frames=-1):
        data, sr = self.sf.read(path, start=start, frames=frames, dtype="float32", always_2d=True)
        return data, sr

    def write(self, path, data, samplerate):
        self.sf.write(path, data, samplerate)

    def move(self, src, dest):
        shutil.move(src, dest)

    def writer(self, path, samplerate, channels, fmt):
        return self.sf.SoundFile(path, "w", samplerate=samplerate, channels=channels,
                                 format={"wav": "WAV", "flac": "FLAC", "mp3": "MP3"}[fmt])


class Stitcher:
    """Writes one stem file from consecutive, overlapping chunks, cross-fading each overlap; only the overlap tail is
    kept in memory."""

    def __init__(self, io, path, fmt, overlap_s=OVERLAP_S):
        self.io, self.path, self.fmt, self.overlap_s = io, path, fmt, overlap_s
        self._writer = None
        self._tail = None
        self.samplerate = None

    def add(self, data, samplerate, first, last):
        np = self.io.np
        if self._writer is None:
            self.samplerate = samplerate
            self._writer = self.io.writer(self.path, samplerate, data.shape[1], self.fmt)
        ov = int(self.overlap_s * samplerate)
        if self._tail is not None:
            n = min(len(self._tail), len(data) // 2, ov)
            ramp = np.linspace(0.0, 1.0, n, endpoint=False, dtype="float32")[:, None]
            self._writer.write(self._tail[-n:] * (1.0 - ramp) + data[:n] * ramp if n else self._tail[:0])
            data = data[n:]
        if last:
            self._writer.write(data)
            self._tail = None
        else:
            keep = min(ov, len(data) // 2)
            self._writer.write(data[:len(data) - keep])
            self._tail = data[len(data) - keep:]

    def close(self):
        if self._writer is not None:
            self._writer.close()
            self._writer = None


def sandbox_write_roots(work_dir, outputs_dir):
    """What a sandboxed (network denied) separation may write: its work and output folders, plus the per-user temp and
    cache folders, because onnxruntime's CoreML provider writes its compiled model there whatever TMPDIR says."""
    import subprocess
    roots = [work_dir, outputs_dir]
    for name in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"):
        try:
            p = subprocess.run(["/usr/bin/getconf", name], capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            p = ""
        if p.startswith("/"):
            roots.append(p)
    return roots


def _real_separator(model_dir, work_dir, fmt):
    """audio-separator, pointed at the folder fetch-model filled; it must not download anything."""
    import logging
    # librosa's numba functions are cached next to the package, which a sandboxed process cannot write.
    os.environ.setdefault("NUMBA_CACHE_DIR", os.path.join(work_dir, ".numba"))
    from audio_separator.separator import Separator
    return Separator(model_file_dir=model_dir, output_dir=work_dir, output_format=fmt.upper(),
                     log_level=logging.WARNING)


def _root_from_prefix():
    """The engines folder, from the pro interpreter's place: <engines>/pro/.venv/bin/python."""
    return os.path.dirname(os.path.dirname(os.path.abspath(sys.prefix)))   # sys.prefix is <engines>/pro/.venv


def _installed(root, entry):
    """The model folder, after checking every pinned file is there with the pinned size."""
    folder = catalog.model_dir(root, entry["id"])
    for spec in pins.STEMS.get(entry["id"], []):
        p = os.path.join(folder, spec["path"])
        if not os.path.isfile(p) or os.path.getsize(p) != spec["size"]:
            raise StemError("The %s model is not installed. Open Engines and install it first." % entry["title"])
    return folder


def separate(req, emit=None, root=None, io=None, separator_factory=None):
    """Runs one separation. Returns {"outputs": [paths], ...}. `io`, `separator_factory` are test seams."""
    emit = emit or cns_proto
    work = os.path.abspath(req.get("work_dir") or "")
    outputs_dir = os.path.abspath(req.get("outputs_dir") or "")
    if not work or not os.path.isdir(work):
        raise StemError("No work folder given.")
    v = validate_request(req, roots=[outputs_dir, work] if req.get("outputs_dir") else None)
    entry = v["entry"]
    root = root or req.get("engines_root") or _root_from_prefix()
    folder = _installed(root, entry)
    io = io or SoundFileIO()
    frames, sr, _ = io.info(v["input"])
    check_audio(frames, sr, io.peak(v["input"]))
    plan = plan_chunks(frames, sr, v["chunk_s"])
    emit.status("Loading %s…" % entry["title"])
    sep = (separator_factory or _real_separator)(folder, work, v["format"])
    sep.load_model(model_filename=entry["load_file"])
    stitchers = {}
    base = re.sub(r"[^\w.\- ]+", "_", os.path.splitext(os.path.basename(v["input"]))[0]) or "audio"
    started = time.time()
    try:
        for i, (a, b) in enumerate(plan):
            chunk_in = os.path.join(work, "chunk_%04d.wav" % i)
            data, _sr = io.read(v["input"], a, b - a)
            io.write(chunk_in, data, _sr)
            del data
            emit.status("Separating part %d of %d…" % (i + 1, len(plan)))
            produced = {}
            for name in sep.separate(chunk_in):
                p = name if os.path.isabs(name) else os.path.join(work, name)
                label = stem_name(p)
                if label:
                    produced[label] = p
            if not produced:
                raise StemError("The model returned no stems. Try another model.")
            arrays = {}
            for label, p in produced.items():
                arrays[label], out_sr = io.read(p)
                os.remove(p)
            if "instrumental" in v["stems"] and "instrumental" not in arrays and "vocals" in arrays:
                rest = [a_ for k, a_ in arrays.items() if k != "vocals"]
                n = min(len(x) for x in rest)
                arrays["instrumental"] = sum(x[:n] for x in rest)
            for label in v["stems"]:
                if label not in arrays:
                    raise StemError("The model did not return the '%s' stem." % label)
                if label not in stitchers:
                    out = os.path.join(work, "%s_%s.%s" % (base, label, v["format"]))
                    stitchers[label] = Stitcher(io, out, v["format"])
                stitchers[label].add(arrays[label], out_sr, i == 0, i == len(plan) - 1)
            del arrays
            os.remove(chunk_in)
            emit.progress((i + 1.0) / len(plan))
    finally:
        for s in stitchers.values():
            s.close()
    outputs = []
    if outputs_dir:
        os.makedirs(outputs_dir, exist_ok=True)
    for label in v["stems"]:
        src = stitchers[label].path
        dest = _unique(os.path.join(outputs_dir or work, os.path.basename(src)))
        io.move(src, dest)
        outputs.append(dest)
    return {"outputs": outputs, "model": entry["id"], "seconds": round(time.time() - started, 2),
            "chunks": len(plan), "license": entry["license"], "verified": entry["verified"]}


def _unique(path):
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    n = 2
    while os.path.exists("%s (%d)%s" % (stem, n, ext)):
        n += 1
    return "%s (%d)%s" % (stem, n, ext)


def fetch_model(root, model_id, emit_fn=None, opener=None):
    """Downloads the pinned files of one catalog model (HTTPS, sha256 checked before the final rename)."""
    entry = catalog.get(model_id)
    if entry is None:
        raise StemError("Unknown separation model: %s." % model_id)
    folder = catalog.model_dir(root, model_id)
    specs = pins.STEMS[model_id]
    total = float(sum(s["size"] for s in specs)) or 1.0
    done = 0.0
    for s in specs:
        base = done
        cns_engines.download(s["url"], os.path.join(folder, s["path"]), s["sha256"], s["size"],
                             lambda event, value=0.0, _b=base, _s=s, **_: cns_proto.progress((_b + value * _s["size"]) / total),
                             opener)
        done += s["size"]
    return {"model": model_id, "folder": folder, "files": [s["path"] for s in specs]}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cns_stems.py")
    ap.add_argument("command", choices=["separate", "fetch-model"])
    ap.add_argument("--root")
    ap.add_argument("--model")
    args = ap.parse_args(sys.argv[1:] if argv is None else argv)
    cns_proto.install_stdout_guard()
    try:
        if args.command == "fetch-model":
            req = {"root": args.root, "model": args.model} if args.root else cns_proto.read_request()
            cns_proto.result(**fetch_model(req["root"], req.get("model") or catalog.DEFAULT_ID))
        else:
            req = cns_proto.read_request()
            cns_proto.result(**separate(req))
        return 0
    except (cns_proto.ProtoError, cns_engines.EngineError) as e:
        cns_proto.fail(str(e))
        return 1
    except Exception as e:  # noqa: BLE001 - the app shows one line, the traceback goes to stderr
        import traceback
        traceback.print_exc()
        cns_proto.fail("Separation failed: %s. Close other apps and try again." % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
