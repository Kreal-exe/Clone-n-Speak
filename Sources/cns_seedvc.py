"""Seed-VC voice conversion for the pro engines: `cns_seedvc.py convert` (Python 3.9+ syntax).

The same job as worker.convert_voice (accent removal, 1.0.3) with the same inference.py arguments, as an event-protocol
command for the Convert page: one JSON request line on stdin, events on stdout (cns_proto). Seed-VC runs in a child
process under sandbox-exec with the network denied and writes only inside the job folder; its models are the pinned set
in cns_pins.SEEDVC_MODELS (offered mode: the default v2 model only; the F0-conditioned models are not pinned, so they
are not offered).

Request: input, target (a sample of the voice, up to 25 s of it is used), steps 10..100 (50), cfg_rate (0.7),
length_adjust (1.0), work_dir, outputs_dir. Result: outputs[1], seconds, peak_gb.
"""
import contextlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_engines  # noqa: E402
import cns_proto  # noqa: E402
import cns_rvc  # noqa: E402
from cns_rvc import RvcError  # noqa: E402

TARGET_SECONDS = 25          # as worker.convert_voice: more of the sample does not help and costs time
MIN_TARGET_SECONDS = 1.0
TIMEOUT = 3 * 3600
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
ONLY_DEFAULT_MODE = "Only the standard Seed-VC voice model is available."


def _num(name, value, lo, hi, default, integer=False):
    return cns_rvc._num(name, value, lo, hi, default, integer)


def validate_request(req):
    """Settings of a request with defaults filled in. Keys that would select a model Seed-VC does not have pinned
    (f0_condition, checkpoint, config, fp16 on, ...) are refused rather than ignored."""
    for key in ("f0_condition", "f0", "checkpoint", "config", "fp16", "auto_f0_adjust"):
        if req.get(key):
            raise RvcError(ONLY_DEFAULT_MODE)
    return {"steps": _num("Steps", req.get("steps"), 10, 100, 50, integer=True),
            "cfg_rate": _num("Guidance", req.get("cfg_rate"), 0.0, 1.5, 0.7),
            "length_adjust": _num("Length", req.get("length_adjust"), 0.5, 2.0, 1.0)}


def build_args(source, target, out_dir, steps=50, cfg_rate=0.7, length_adjust=1.0):
    """Arguments of Seed-VC's inference.py: exactly what worker.convert_voice (1.0.3) passes, after the script name."""
    return ["inference.py", "--source", source, "--target", target, "--output", out_dir,
            "--diffusion-steps", str(int(steps)), "--length-adjust", str(float(length_adjust)),
            "--inference-cfg-rate", str(float(cfg_rate)), "--fp16", "False"]


def trim_wav(src, dst, seconds):
    """Writes the first `seconds` of a 16-bit WAV to dst; returns the length written."""
    with contextlib.closing(wave.open(src, "rb")) as r:
        frames = min(r.getnframes(), int(r.getframerate() * seconds))
        data = r.readframes(frames)
        with contextlib.closing(wave.open(dst, "wb")) as w:
            w.setnchannels(r.getnchannels())
            w.setsampwidth(r.getsampwidth())
            w.setframerate(r.getframerate())
            w.writeframes(data)
        return frames / float(r.getframerate())


def sandboxed_command(root, cmd, tmp):
    """cmd wrapped in sandbox-exec: network denied, writes only into the job folder, the Seed-VC folder (Hugging Face
    locks, numba cache) and the MPS graph cache. Used for the Seed-VC run and, by the installer, its warm-up."""
    profile = cns_engines.sandbox_profile(True, [tmp, cns_engines.seedvc_dir(root)] + cns_rvc.mps_cache_roots())
    return [SANDBOX_EXEC, "-p", profile] + list(cmd)


def wrap_command(root, cmd, tmp, env=None, exists=os.path.exists):
    """The app starts this script already inside its sandbox (CNS_SANDBOXED=1 and CNS_SANDBOX_FILE both set): then the
    child inherits it and is not wrapped again. Otherwise it is wrapped here, and without sandbox-exec Seed-VC
    does not run (it must never run with network access)."""
    env = os.environ if env is None else env
    if env.get("CNS_SANDBOXED") == "1" and env.get("CNS_SANDBOX_FILE"):
        return list(cmd)
    if not exists(SANDBOX_EXEC):
        raise RvcError("Seed-VC needs the macOS sandbox (sandbox-exec), which is missing, so it was not started.")
    return sandboxed_command(root, cmd, tmp)


def child_env(root, tmp):
    # numba (librosa) caches compiled code on disk and fails without a writable cache folder: it gets one inside the
    # Seed-VC folder, which the sandbox allows writes to
    extra = dict(cns_engines.seedvc_env(root), TMPDIR=tmp,
                 NUMBA_CACHE_DIR=os.path.join(cns_engines.seedvc_dir(root), "numba-cache"))
    return cns_engines._safe_env(root, extra)


def _wait(proc, label="Converting"):
    t0, last = time.time(), time.time()
    while proc.poll() is None:
        if time.time() - t0 > TIMEOUT:
            proc.kill()
            raise RvcError("Seed-VC took too long and was stopped.")
        time.sleep(1)
        if time.time() - last >= 15:
            cns_proto.status("%s… %d s" % (label, time.time() - t0))
            last = time.time()
    return proc.returncode


def cmd_convert(req):
    params = validate_request(req)
    if not req.get("input") or not req.get("target"):
        raise RvcError("Choose a recording and a voice sample.")
    root = cns_rvc.engine_root(req)
    src_dir = os.path.join(cns_engines.seedvc_dir(root), "seed-vc")
    py = sys.executable
    if not os.path.isfile(os.path.join(src_dir, "inference.py")):
        raise RvcError("Seed-VC is not installed. Open Engines and press Install.")
    outdir = cns_rvc.output_dir(req)
    work = req.get("work_dir") or tempfile.mkdtemp(prefix="cns-seedvc-")
    tmp = os.path.join(work, "seedvc")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    cns_proto.status("Preparing the recordings…")
    source = cns_rvc.prepare_input(req["input"], os.path.join(tmp, "prep"), 0)
    ref_full = cns_rvc.prepare_input(req["target"], os.path.join(tmp, "prep"), 1)
    ref = os.path.join(tmp, "target.wav")
    if trim_wav(ref_full, ref, TARGET_SECONDS) < MIN_TARGET_SECONDS:
        raise RvcError("The voice sample is too short. Use at least a few seconds of clear speech.")
    out_dir = os.path.join(tmp, "out")
    os.makedirs(out_dir)
    cmd = [py] + build_args(source, ref, out_dir, **params)
    cmd = wrap_command(root, cmd, tmp)
    cns_proto.status("Converting with Seed-VC…")
    cns_proto.progress(0.05)
    t0 = time.time()
    log_path = os.path.join(tmp, "seedvc.log")
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(cmd, cwd=src_dir, env=child_env(root, tmp), stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT)
        try:
            code = _wait(proc)
        except BaseException:
            proc.kill()
            raise
    produced = sorted(n for n in os.listdir(out_dir) if n.lower().endswith(".wav")) if os.path.isdir(out_dir) else []
    if code != 0 or not produced:
        with open(log_path, "rb") as f:
            tail = f.read()[-6000:].decode("utf-8", "replace")
        print(tail, file=sys.stderr, flush=True)
        raise RvcError("Seed-VC failed — see the log on the Setup page. Close other apps and try again.")
    dest = cns_rvc.unique_path(outdir, "%s_seedvc" % cns_rvc.safe_stem(req["input"]), ".wav")
    shutil.move(os.path.join(out_dir, produced[0]), dest)
    cns_proto.progress(1.0)
    import resource
    child_gb = round(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1e9, 2)   # bytes on macOS (RSS, not MPS)
    cns_proto.result(outputs=[dest], seconds=round(time.time() - t0, 2), peak_gb=child_gb)


COMMANDS = {"convert": cmd_convert}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cns_proto.install_stdout_guard()
    if len(argv) != 1 or argv[0] not in COMMANDS:
        cns_proto.fail("Usage: cns_seedvc.py convert")
        return 2
    try:
        COMMANDS[argv[0]](cns_proto.read_request())
    except (RvcError, cns_proto.ProtoError, cns_engines.EngineError) as e:
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
