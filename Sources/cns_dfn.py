"""DeepFilterNet3 noise removal (Clone'n'Speak 2.0, Audio Tools), through the pinned `deep-filter` 0.5.6 binary.

The binary (MIT or Apache-2.0, model inside) is downloaded on request into <bin_dir>/deep-filter, checked against
a fixed length and SHA-256, and run as a child process per channel: the audio is resampled to 48 kHz, written as a
16-bit mono WAV, cleaned with `-D` (delay compensation) and read back from a temporary folder that is always removed.
The binary's output is captured: nothing here prints to stdout (the worker's protocol channel). Python 3.9 compatible.
"""
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import cns_core as core

VERSION = "0.5.6"
URL = "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-aarch64-apple-darwin"
SHA256 = "4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081"
SIZE = 27877081
RATE = 48000
DEFAULT_DB = 18.0
MISSING = "DeepFilterNet is not installed. Download DeepFilterNet in Audio Tools, then try again."


def bin_dir():
    """$CNS_BIN_DIR, else <this module's folder>/bin (the app sets CNS_BIN_DIR to OVPaths binDir)."""
    return os.environ.get("CNS_BIN_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")


BINARY = os.path.join(bin_dir(), "deep-filter")


class DfnMissing(RuntimeError):
    """The binary has not been downloaded yet; the message names the action."""


def _installed():
    return os.path.isfile(BINARY) and os.access(BINARY, os.X_OK)


# --------------------------------------------------------------------------
# Running the binary
# --------------------------------------------------------------------------
_help_cache = {}


def _has_atten_flag():
    """True when `deep-filter --help` lists --atten-lim (cached per binary file and modification time)."""
    try:
        key = (BINARY, os.stat(BINARY).st_mtime_ns)
    except OSError:
        return True
    if key not in _help_cache:
        try:
            out = subprocess.run([BINARY, "--help"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=30)
            _help_cache[key] = b"--atten-lim" in out.stdout
        except (OSError, subprocess.SubprocessError):
            _help_cache[key] = True
    return _help_cache[key]


def _clamp_db(strength_db):
    try:
        v = float(strength_db)
    except (TypeError, ValueError):
        v = float("nan")
    if v != v:
        raise core.AudioInputError("bad_param", "The strength must be a number from 1 to 30 dB.")
    return min(30.0, max(1.0, v))


def _run_channel(x48, strength_db, use_flag, tmp):
    """One mono float32 channel at 48 kHz -> cleaned mono channel of the same length."""
    import numpy as np
    src = os.path.join(tmp, "in.wav")
    out_dir = os.path.join(tmp, "out")
    os.makedirs(out_dir, exist_ok=True)
    result = os.path.join(out_dir, "in.wav")
    if os.path.exists(result):
        os.remove(result)  # a leftover of the previous channel must not pass for this one
    core.write_audio(src, x48, RATE, subtype="pcm16")
    cmd = [BINARY, "-D"]
    if use_flag:
        cmd += ["-a", "%g" % strength_db]
    cmd += ["-o", out_dir, src]
    seconds = len(x48) / float(RATE)
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=120 + 4 * seconds)
    except subprocess.TimeoutExpired:
        raise RuntimeError("DeepFilterNet took too long and was stopped. Try a shorter recording.")
    except OSError as e:
        raise RuntimeError("DeepFilterNet could not be started (%s). Download it again in Audio Tools." % e)
    if proc.returncode != 0 or not os.path.isfile(result):
        tail = (proc.stderr or proc.stdout or b"").decode("utf-8", "replace").strip()[-400:]
        raise RuntimeError("DeepFilterNet failed (exit %s). %s" % (proc.returncode, tail))
    y, rate = core.read_audio(result, mono=True, max_seconds=0)
    if rate != RATE:
        y = core.resample(y, rate, RATE)
    n = len(x48)
    y = y[:n] if len(y) >= n else np.pad(y, (0, n - len(y)))
    if not use_flag:  # no attenuation-limit flag: mix dry and wet, w = (strength - 1) / 29
        w = (strength_db - 1.0) / 29.0
        y = x48 * (1.0 - w) + y * w
    return y.astype(np.float32)


def dfn_denoise(wav, sr, strength_db=DEFAULT_DB):
    """wav float32 (n,) or (n, ch) at `sr` -> same shape and rate, cleaned. strength_db is clamped to 1..30."""
    import numpy as np
    strength_db = _clamp_db(strength_db)
    if not _installed():
        raise DfnMissing(MISSING)
    wav = np.asarray(wav, dtype=np.float32)
    if wav.shape[0] == 0:
        return wav
    n = wav.shape[0]
    use_flag = _has_atten_flag()
    tmp = tempfile.mkdtemp(prefix="cns-dfn-")
    try:
        def one(ch):
            x48 = core.resample(ch, sr, RATE)
            y = _run_channel(np.ascontiguousarray(x48, dtype=np.float32), strength_db, use_flag, tmp)
            y = core.resample(y, RATE, sr)
            return (y[:n] if len(y) >= n else np.pad(y, (0, n - len(y)))).astype(np.float32)
        return core.map_channels(wav, one)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------
def dfn_status(req=None):
    if not _installed():
        return {"installed": False, "version": None, "size": 0, "path": None}
    return {"installed": True, "version": VERSION, "size": os.path.getsize(BINARY), "path": BINARY}


def _runs():
    """True when `deep-filter --version` starts; None when the system killed it (unsigned binary)."""
    try:
        proc = subprocess.run([BINARY + ".part", "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
    except OSError:
        return False
    if proc.returncode < 0:
        return None
    return proc.returncode == 0


def dfn_install(req=None):
    part = BINARY + ".part"
    os.makedirs(os.path.dirname(BINARY), exist_ok=True)
    core.emit_status("Downloading DeepFilterNet…")
    core.emit_progress(0.0)
    try:
        digest = hashlib.sha256()
        done = 0
        with urllib.request.urlopen(URL, timeout=60) as resp, open(part, "wb") as f:  # overwrites an old .part
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                digest.update(chunk)
                done += len(chunk)
                core.emit_progress(min(0.95, done / float(SIZE)))
        if done != SIZE:
            raise RuntimeError("The DeepFilterNet download is incomplete (%d of %d bytes). Try again." % (done, SIZE))
        if digest.hexdigest() != SHA256:
            raise RuntimeError("The DeepFilterNet download failed the checksum test and was discarded. Try again.")
        os.chmod(part, 0o755)
        ok = _runs()
        if ok is None:  # killed: the binary has no signature, sign it ad hoc and try once more
            subprocess.run(["codesign", "--force", "--sign", "-", part], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            ok = _runs()
        if not ok:
            raise RuntimeError("The downloaded DeepFilterNet does not start on this Mac.")
        os.replace(part, BINARY)
    except BaseException:
        try:
            os.remove(part)
        except OSError:
            pass
        raise
    core.emit_progress(1.0)
    return {"installed": True}


def dfn_remove(req=None):
    for p in (BINARY, BINARY + ".part"):
        try:
            os.remove(p)
        except OSError:
            pass
    return {"installed": False}


def dfn_apply(req):
    core.free_models()
    strength = _clamp_db(req.get("strength_db", DEFAULT_DB))
    if not _installed():
        raise DfnMissing(MISSING)
    wav, sr = core.read_audio(req["audio"], mono=False)
    core.emit_status("Removing noise…")
    core.emit_progress(0.1)
    out = dfn_denoise(wav, sr, strength)
    seconds = core.write_audio(req["out"], out, sr, subtype="pcm16")
    core.emit_progress(1.0)
    return {"path": req["out"], "seconds": seconds, "snr_hint": None}


COMMANDS = {
    "dfn_status": dfn_status,
    "dfn_install": dfn_install,
    "dfn_remove": dfn_remove,
    "dfn_apply": dfn_apply,
}


# --------------------------------------------------------------------------
# Hook: Enhance with mode "dfn" cleans the sample with DeepFilterNet instead of the spectral gate
# --------------------------------------------------------------------------
def _pre_enhance(req, wav, sr):
    if req.get("mode") != "dfn":
        return wav
    try:
        src, rate = core.read_audio(req["audio"], mono=True, max_seconds=0)  # at its own rate, as the binary likes
        out = dfn_denoise(src, rate, req.get("strength_db", DEFAULT_DB))
    except DfnMissing as e:
        raise core.AudioInputError("unsupported", str(e))
    req["denoise"] = False
    return core.resample(out, rate, sr)


PRE_ENHANCE_HOOK = _pre_enhance
if _pre_enhance not in core.PRE_ENHANCE:
    core.PRE_ENHANCE.append(_pre_enhance)


# --------------------------------------------------------------------------
# Test registry: a stub instead of the real binary
# --------------------------------------------------------------------------
STUB = """#!/bin/sh
exec %s - "$@" <<'PYEOF'
import os, shutil, sys
a = sys.argv[1:]
if "--version" in a or "-V" in a:
    print("deep_filter 0.5.6"); sys.exit(0)
if "--help" in a:
    print("  -a, --atten-lim-db <ATTEN_LIM_DB>"); sys.exit(0)
out = a[a.index("-o") + 1]
os.makedirs(out, exist_ok=True)
shutil.copy(a[-1], os.path.join(out, os.path.basename(a[-1])))
PYEOF
"""


def _tool_setup(tmpdir):
    global BINARY
    old = BINARY
    BINARY = os.path.join(tmpdir, "deep-filter")
    with open(BINARY, "w") as f:
        f.write(STUB % shlex.quote(sys.executable))
    os.chmod(BINARY, 0o755)

    def restore():
        global BINARY
        BINARY = old
    return restore


core.TOOLS["dfn_apply"] = {
    "request": lambda i, o: {"cmd": "dfn_apply", "audio": i, "out": o, "strength_db": 18},
    "setup": _tool_setup,
    "streams": False,
}
