"""RVC voice training, dataset review and the overtraining detector (the pro environment, Applio as the engine).

Python 3.9+, stdlib only at import time (numpy / soundfile / tensorboard are imported inside the functions that need
them). Events on the cns_proto line protocol; one JSON request on stdin.

    cns_train.py run       preprocess -> extract -> train -> index -> export (any subset, in that order)
    cns_train.py review    check a folder of recordings before training (per-file metrics, verdict, advice)
    cns_train.py clean     delete the G_/D_ checkpoints of a trained voice (1.3 GB); keeps the weights and the index

Applio scripts run as child processes, exactly like Applio's own core.run_*_script, but their output is read here so
progress, the 120 s watchdog and a clean stop (SIGTERM) work. The training folder <root>/training/<name> is never removed
by a stop or a failure, it is what `resume` continues from; the job's work/ folder is emptied.
"""
import argparse
import glob
import hashlib
import json
import math
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_proto  # noqa: E402

STAGES = ("preprocess", "extract", "train", "index", "export")
STAGE_WEIGHTS = (("preprocess", 0.03), ("extract", 0.10), ("train", 0.82), ("index", 0.03), ("export", 0.02))
SAMPLE_RATES = (32000, 40000, 48000)
TRAIN_WATCHDOG_S = 120
STAGE_WATCHDOG_S = 300
BATCH_DEFAULT = 4
BATCH_TIGHT = 2
TIGHT_FREE_GB = 11.5
STALLED = "Stalled — probably low memory. Close other apps and retry."
NOTHING_TO_CONTINUE = "Nothing to continue — start training first."

# Applio's rules for a good dataset, plus ours (see the module docstring of review()).
SILENCE_DB = -50.0
SILENCE_SHARE = 0.35
LONG_PAUSE_S = 2.0
LONG_EDGE_S = 1.0
LEVEL_DIFF_DB = 6.0
MIN_TOTAL_S = 180.0
RECOMMENDED_TOTAL_S = 600.0
POOR_TOTAL_S = 60.0
MIN_SR = 32000
CLIP_SHARE = 0.005
MIN_FILE_S = 1.0
AUDIO_EXT = (".wav", ".flac", ".mp3", ".ogg", ".m4a", ".aac", ".aiff", ".aif", ".opus")

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_PROGRESS_RE = re.compile(r"epoch=(\d+) \| step=(\d+)(?: \| batch=(\d+)/(\d+))?")
_WEIGHTS_RE = re.compile(r"^(?P<name>.+)_(?P<e>\d+)e_(?P<s>\d+)s\.pth$")
_CKPT_RE = re.compile(r"^[GD]_\d+\.pth$")


# Training runs offline and may write only where it must: no IP traffic, all file writes denied except the given roots,
# the terminal/null devices and the per-user cache folders macOS hands to MPS (shader cache). The generic profile of
# cns_engines also denies Unix sockets, which breaks torch's DataLoader workers (torch_shm_manager), so this one is own.
NO_SANDBOX_ENV = "CNS_TRAIN_NO_SANDBOX"   # tests only; no request key can turn the sandbox off
SANDBOX_EXEC = "/usr/bin/sandbox-exec"


def train_profile(write_roots):
    import cns_engines as eng
    allow = ['(literal "/dev/null")', '(regex #"^/dev/tty")', '(regex #"^/dev/dtracehelper$")']
    for r in write_roots:
        allow.append("(subpath %s)" % eng._sb_quote(os.path.realpath(r)))
    for d in _darwin_cache_dirs():
        allow.append("(subpath %s)" % eng._sb_quote(d))
    return ("(version 1)\n(allow default)\n(deny network-outbound (remote ip))\n(deny network-inbound (local ip))\n"
            "(deny network-bind (local ip))\n(deny file-write*)\n(allow file-write* %s)\n" % " ".join(allow))


def _darwin_cache_dirs():
    out = []
    try:
        for key in ("DARWIN_USER_CACHE_DIR", "DARWIN_USER_TEMP_DIR"):
            r = subprocess.run(["/usr/bin/getconf", key], capture_output=True, text=True, timeout=5).stdout.strip()
            if r.startswith("/"):
                out.append(os.path.realpath(r))
    except Exception:  # noqa: BLE001
        pass
    return out


class TrainError(RuntimeError):
    pass


class Stopped(Exception):
    pass


# ------------------------------------------------------------------------------------------------------- small helpers

def slug(name):
    """A voice name is used as a folder name and as an Applio argument, so it is letters, digits, _ and - only."""
    if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
        raise TrainError("Use only letters, numbers, - and _ in the voice name (up to 64 characters).")
    return name


def parse_progress(line):
    """'<name> | epoch=3 | step=42 | batch=5/14' -> (epoch, step, batch|None, batches|None), else None."""
    m = _PROGRESS_RE.search(line or "")
    if not m:
        return None
    b, n = m.group(3), m.group(4)
    return int(m.group(1)), int(m.group(2)), (int(b) if b else None), (int(n) if n else None)


def is_epoch_summary(line):
    """The line Applio prints once an epoch is finished: it has time= and no batch=."""
    p = parse_progress(line)
    return bool(p and p[2] is None and "time=" in line)


class EpochFraction:
    """Fraction of the training stage done: a line with batch=a/b is part way through epoch e, a line without batch
    means epoch e is finished. total_epoch counts all epochs, start_epoch is how many a resumed run already has, so
    the bar of a resumed run starts at 0, not at the old epochs. Never goes down."""

    def __init__(self, total_epoch, start_epoch=0):
        self.todo = max(1, int(total_epoch) - int(start_epoch))
        self.start = int(start_epoch)
        self.last = 0.0

    def update(self, epoch, batch=None, batches=None):
        done = epoch - 1 - self.start
        if batch is None:
            done += 1
        elif batches:
            done += min(1.0, batch / float(batches))
        self.last = max(self.last, max(0.0, min(1.0, done / float(self.todo))))
        return self.last


def default_batch(free_gb):
    """Batch 4 needs about 10 GB at peak; below 11.5 GB free the safer 2 (8.2 GB) is used."""
    if free_gb is None:
        return BATCH_DEFAULT
    return BATCH_DEFAULT if free_gb >= TIGHT_FREE_GB else BATCH_TIGHT


def train_args(name, save_every_epoch, total_epoch, pretrain_g, pretrain_d, gpu, batch, sample_rate):
    """The 14 positional arguments of Applio's rvc/train/train.py, in its order."""
    return [str(x) for x in (name, save_every_epoch, total_epoch, pretrain_g, pretrain_d, gpu, batch, sample_rate,
                             True,    # save_only_latest: one G_/D_ pair, not 1.3 GB per saved step
                             True,    # save_every_weights: a small <name>_<e>e_<s>s.pth per epoch (best-epoch export)
                             False,   # cache_data_in_gpu
                             False,   # cleanup
                             "HiFi-GAN",
                             False)]  # checkpointing


def preprocess_args(exp_dir, dataset, sample_rate, cores):
    return [exp_dir, dataset, str(sample_rate), str(cores), "Automatic", "False", "3.0", "0.3", "none"]


def extract_args(exp_dir, f0_method, cores, gpu, sample_rate, embedder):
    return [exp_dir, f0_method, str(cores), str(gpu), str(sample_rate), embedder, "None", "2"]


def weights_files(exp_dir, name):
    """[(epoch, step, path)] of the per-epoch <name>_<e>e_<s>s.pth files, oldest first."""
    out = []
    for p in glob.glob(os.path.join(exp_dir, "*.pth")):
        m = _WEIGHTS_RE.match(os.path.basename(p))
        if m and m.group("name") == name:
            out.append((int(m.group("e")), int(m.group("s")), p))
    return sorted(out)


def checkpoints(exp_dir):
    return {k: sorted(glob.glob(os.path.join(exp_dir, k + "_*.pth"))) for k in ("G", "D")}


def reached_epoch(exp_dir, name):
    w = weights_files(exp_dir, name)
    return w[-1][0] if w else 0


def nearest_weights(exp_dir, name, epoch):
    """The weights file of the epoch closest to `epoch` (exact when it exists)."""
    w = weights_files(exp_dir, name)
    if not w:
        return None
    return min(w, key=lambda t: (abs(t[0] - epoch), -t[0]))[2]


def clean_checkpoints(exp_dir):
    """Deletes only G_<n>.pth / D_<n>.pth directly inside exp_dir. Returns the bytes freed."""
    freed = 0
    if not os.path.isdir(exp_dir):
        return 0
    for f in os.listdir(exp_dir):
        p = os.path.join(exp_dir, f)
        if _CKPT_RE.match(f) and os.path.isfile(p) and not os.path.islink(p):
            freed += os.path.getsize(p)
            os.remove(p)
    return freed


# --------------------------------------------------------------------------------------------- overtraining detector

class OvertrainDetector:
    """Watches the per-epoch generator losses (loss_mel and loss_gen_all). Both are smoothed with an EMA (alpha) and
    averaged after each is divided by its own first value, which gives one score that is lower when the voice is
    better. `improving`: a new minimum of the score was set within the last `patience` epochs; `plateau`: no new
    minimum for `patience` epochs; `overtrained`: plateau and the score is `rise` (relative) above the best.
    It never stops anything; the UI offers "Stop and use epoch N" with best_epoch."""

    MIN_GAIN = 0.005   # a new minimum must beat the best by 0.5 %, or an EMA creeping to a flat line would count

    def __init__(self, patience=10, ema_alpha=0.3, rise=0.05):
        self.patience = max(1, int(patience))
        self.alpha = float(ema_alpha)
        self.rise = float(rise)
        self.epochs = 0
        self.best_epoch = None
        self.best_score = None
        self._ema = None
        self._first = None
        self._since_best = 0
        self._raw = []
        self.state = "improving"

    @staticmethod
    def default_patience(total_epoch):
        return max(10, int(math.ceil(0.15 * int(total_epoch))))

    def update(self, epoch, loss_mel, loss_gen_all):
        vals = (float(loss_mel), float(loss_gen_all))
        if self._ema is None:
            self._ema = list(vals)
            self._first = [v if v else 1.0 for v in vals]
        else:
            self._ema = [self.alpha * v + (1 - self.alpha) * e for v, e in zip(vals, self._ema)]
        score = sum(e / f for e, f in zip(self._ema, self._first)) / 2.0
        self.epochs += 1
        self._raw.append((sum(v / f for v, f in zip(vals, self._first)) / 2.0, int(epoch)))
        if self.best_score is None or score < self.best_score * (1.0 - self.MIN_GAIN):
            # the EMA lags the real minimum by a few epochs: the best epoch is the best raw one of the last few
            self.best_score, self._since_best = score, 0
            self.best_epoch = min(self._raw[-4:])[1]
        else:
            self._since_best += 1
        if self._since_best < self.patience:
            self.state = "improving"
        elif score > self.best_score * (1.0 + self.rise):
            self.state = "overtrained"
        else:
            self.state = "plateau"
        return self.state

    def report(self):
        return {"state": self.state, "best_epoch": self.best_epoch, "epochs_seen": self.epochs,
                "epochs_since_best": self._since_best, "patience": self.patience}


def read_epoch_losses(eval_dir):
    """[(step, loss_mel, loss_gen_all)] from the tensorboard events Applio writes once per epoch (needs tensorboard,
    which the pro environment has). Missing folder, no events, or an unreadable file -> []."""
    try:
        from tensorboard.backend.event_processing.event_accumulator import EventAccumulator
        acc = EventAccumulator(eval_dir, size_guidance={"scalars": 0})
        acc.Reload()
        tags = acc.Tags().get("scalars", [])
        if "loss/g/mel" not in tags or "loss/g/total" not in tags:
            return []
        mel = {e.step: e.value for e in acc.Scalars("loss/g/mel")}
        gen = {e.step: e.value for e in acc.Scalars("loss/g/total")}
        return [(s, mel[s], gen[s]) for s in sorted(mel) if s in gen]
    except Exception:  # noqa: BLE001  tensorboard missing or a half-written event file: the detector just has no data
        return []


# ------------------------------------------------------------------------------------------------------ dataset review

def analyze_samples(x, sr, channels=1):
    """Metrics of one file from float samples in -1..1 (mono). Pure numpy, no I/O."""
    import numpy as np
    x = np.asarray(x, dtype=np.float32)
    dur = len(x) / float(sr) if sr else 0.0
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    clip = float(np.mean(np.abs(x) >= 0.999)) if len(x) else 0.0
    rms = float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0
    out = {"duration_s": round(dur, 3), "sample_rate": int(sr), "channels": int(channels),
           "peak_db": round(20 * math.log10(max(peak, 1e-9)), 2), "clip_share": round(clip, 5),
           "rms_db": round(20 * math.log10(max(rms, 1e-9)), 2),
           "hash": hashlib.sha256(np.round(x * 32767).astype("<i2").tobytes()).hexdigest()}
    frame_s = 0.02
    n = max(1, int(sr * frame_s))
    count = len(x) // n
    if count == 0:
        out.update(silence_share=1.0 if rms < 10 ** (SILENCE_DB / 20) else 0.0, longest_pause_s=0.0, lead_s=0.0, trail_s=0.0)
        return out
    frames = x[:count * n].reshape(count, n)
    db = 20 * np.log10(np.maximum(np.sqrt(np.mean(np.square(frames), axis=1)), 1e-9))
    silent = db < SILENCE_DB
    longest = run = 0
    for s in silent:
        run = run + 1 if s else 0
        longest = max(longest, run)
    lead = trail = 0
    for s in silent:
        if not s:
            break
        lead += 1
    for s in silent[::-1]:
        if not s:
            break
        trail += 1
    out.update(silence_share=round(float(np.mean(silent)), 4), longest_pause_s=round(longest * frame_s, 2),
               lead_s=round(lead * frame_s, 2), trail_s=round(trail * frame_s, 2))
    return out


def decode_audio(path):
    """(mono float32 samples, sample rate, channels) through soundfile (pro environment). Raises TrainError."""
    try:
        import numpy as np
        import soundfile as sf
        data, sr = sf.read(path, dtype="float32", always_2d=True)
    except Exception as e:  # noqa: BLE001
        raise TrainError("Can't read %s: %s" % (os.path.basename(path), e))
    return np.mean(data, axis=1), int(sr), int(data.shape[1])


def review_metrics(files):
    """files: [(name, metrics dict from analyze_samples | {'error': text})] -> the report dict.

    Thresholds are Applio's (silence >= 35 %, a pause > 2 s, an edge > 1 s, level 6 dB off the median, duplicates only
    when the decoded audio is identical) plus ours (total < 3 min is too little, 10 min or more is recommended,
    sample rate < 32 kHz, clipping > 0.5 %, a file < 1 s)."""
    import statistics
    rows = [dict(m, file=n) for n, m in files]
    good = [r for r in rows if "error" not in r]
    med = statistics.median([r["rms_db"] for r in good]) if good else 0.0
    seen = {}
    for r in rows:
        r["flags"] = []
        if "error" in r:
            r["flags"].append("unreadable")
            continue
        r["level_vs_median_db"] = round(r["rms_db"] - med, 2)
        if r["silence_share"] >= SILENCE_SHARE:
            r["flags"].append("excessive_silence")
        if r["longest_pause_s"] > LONG_PAUSE_S:
            r["flags"].append("long_pause")
        if r["lead_s"] > LONG_EDGE_S or r["trail_s"] > LONG_EDGE_S:
            r["flags"].append("long_edge")
        if abs(r["level_vs_median_db"]) >= LEVEL_DIFF_DB:
            r["flags"].append("level_outlier")
        if r["clip_share"] > CLIP_SHARE:
            r["flags"].append("clipping")
        if r["sample_rate"] < MIN_SR:
            r["flags"].append("low_sample_rate")
        if r["duration_s"] < MIN_FILE_S:
            r["flags"].append("too_short")
        first = seen.setdefault(r["hash"], r["file"])
        if first != r["file"]:
            r["flags"].append("duplicate")
            r["duplicate_of"] = first
    total = round(sum(r["duration_s"] for r in good), 2)
    dataset_flags = []
    if total < MIN_TOTAL_S:
        dataset_flags.append("short_dataset")
    advice = _advice(rows, total, dataset_flags)
    flagged = [r for r in rows if r["flags"]]
    if not good or total < POOR_TOTAL_S or len(flagged) * 2 >= len(rows):
        verdict = "poor"
    elif flagged or dataset_flags:
        verdict = "warn"
    else:
        verdict = "ok"
    return {"verdict": verdict, "total_s": total, "files": rows, "dataset_flags": dataset_flags, "advice": advice,
            "median_rms_db": round(med, 2)}


_ADVICE = {
    "excessive_silence": "Cut the silence out of {files}: it is 35% or more of the file.",
    "long_pause": "Trim pauses longer than 2 seconds in {files}.",
    "long_edge": "Trim the silence at the start or end (over 1 second) of {files}.",
    "level_outlier": "Bring {files} to the same loudness as the rest (they are 6 dB or more off).",
    "clipping": "Re-record {files} quieter: the sound is clipped. Or remove them.",
    "low_sample_rate": "Replace {files} with a recording of 32 kHz or better.",
    "too_short": "Remove {files}: under 1 second is too little to learn from.",
    "duplicate": "Remove {files}: they repeat another file exactly.",
    "unreadable": "Replace or remove {files}: they can't be read.",
}


def _advice(rows, total, dataset_flags):
    out = []
    if "short_dataset" in dataset_flags:
        out.append({"code": "short_dataset", "files": [],
                    "action": "Add more speech: you have %d s, at least 3 minutes is needed and 10 minutes or more "
                              "gives a clearly better voice." % round(total)})
    elif total < RECOMMENDED_TOTAL_S:
        out.append({"code": "more_is_better", "files": [],
                    "action": "A longer recording (10 minutes or more) gives a better voice."})
    for code, text in _ADVICE.items():
        names = [r["file"] for r in rows if code in r["flags"]]
        if names:
            shown = ", ".join(names[:5]) + (" and %d more" % (len(names) - 5) if len(names) > 5 else "")
            out.append({"code": code, "files": names, "action": text.format(files=shown)})
    return out


def review_folder(folder, emit_progress=None):
    folder = os.path.realpath(os.path.expanduser(str(folder)))
    if not os.path.isdir(folder):
        raise TrainError("Dataset folder not found.")
    names = sorted(f for f in os.listdir(folder) if f.lower().endswith(AUDIO_EXT) and not f.startswith("."))
    if not names:
        raise TrainError("No audio files in this folder.")
    rows = []
    for i, n in enumerate(names):
        p = os.path.join(folder, n)
        try:
            x, sr, ch = decode_audio(p)
            rows.append((n, analyze_samples(x, sr, ch)))
        except TrainError as e:
            rows.append((n, {"error": str(e)}))
        if emit_progress:
            emit_progress((i + 1) / float(len(names)))
    return review_metrics(rows)


# ---------------------------------------------------------------------------------------------------- child processes

def _kill_group(proc, sig=signal.SIGTERM):
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def run_child(argv, env, cwd, on_line, watchdog=None, idle_s=None, popen=subprocess.Popen, should_stop=None):
    """Runs argv in its own process group and feeds every output line (stdout+stderr) to on_line(line).
    watchdog: a cns_proto.Watchdog whose on_stall is set by the caller; it is poked by `poke_if(line)`; when it fires
    the whole group is killed and TrainError(STALLED) raised. should_stop(): truthy -> group killed, Stopped raised.
    Returns the exit code."""
    proc = popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                 errors="replace", start_new_session=True)
    q = queue.Queue()

    def reader():
        try:
            for line in proc.stdout:
                q.put(line)
        finally:
            q.put(None)

    threading.Thread(target=reader, daemon=True).start()
    stalled = False
    try:
        done = False
        while True:
            try:
                line = q.get(timeout=0.1)
            except queue.Empty:
                line = ""
            if line is None:
                done = True
            elif line:
                on_line(line.rstrip("\n"))
            if should_stop and should_stop():
                _kill_group(proc)
                raise Stopped()
            if watchdog is not None and watchdog.check():
                stalled = True
                break
            if done:
                break
            if not line and proc.poll() is not None and q.empty():
                time.sleep(0.05)
        if stalled:
            _kill_group(proc, signal.SIGKILL)
            raise TrainError(STALLED)
        return proc.wait()
    finally:
        if proc.poll() is None:
            _kill_group(proc, signal.SIGKILL)
            try:
                proc.wait(timeout=10)
            except Exception:  # noqa: BLE001
                pass


# ---------------------------------------------------------------------------------------------------------- the runner

def _engine_paths(req):
    root = req.get("root") or os.environ.get("CNS_ENGINES_ROOT")
    if not root and not (req.get("applio") and req.get("python")):
        raise TrainError("No engines folder given.")
    if root:
        import cns_engines as eng
        root = os.path.abspath(root)
        py = req.get("python") or eng.python_for(root, "rvc-core")
        applio = req.get("applio") or eng.applio_dir(root)
        training = req.get("training_dir") or eng.training_dir(root)
        weights = req.get("weights_dir") or eng.weights_dir(root)
    else:
        py, applio = req["python"], req["applio"]
        training, weights = req.get("training_dir"), req.get("weights_dir")
    if not training or not weights:
        raise TrainError("No training folder given.")
    for p in (py, applio):
        if not os.path.exists(p):
            raise TrainError("The RVC engine is not installed — install it in Engines.")
    return {"python": py, "applio": os.path.abspath(applio), "training": os.path.abspath(training),
            "weights": os.path.abspath(weights)}


class Trainer:
    def __init__(self, req, emit=None, memory=None, popen=subprocess.Popen, clock=time.monotonic):
        self.req = req
        self.emit = emit or cns_proto
        self.paths = _engine_paths(req)
        self.name = slug(req.get("name"))
        self.exp = os.path.join(self.paths["training"], self.name)
        self.sr = int(req.get("sample_rate", 40000))
        if self.sr not in SAMPLE_RATES:
            raise TrainError("Sample rate must be 32000, 40000 or 48000.")
        self.total = int(req.get("total_epoch", 0))
        if self.total < 1:
            raise TrainError("Choose how many epochs to train.")
        self.save_every = max(1, int(req.get("save_every_epoch", 1)))
        self.resume = bool(req.get("resume"))
        self.f0 = req.get("f0_method", "rmvpe")
        self.embedder = req.get("embedder", "contentvec")
        self.index_algorithm = req.get("index_algorithm", "Auto")
        self.gpu = "-" if req.get("device") == "cpu" else "0"
        self.work = req.get("work_dir")
        self.models_dir = req.get("models_dir")
        steps = req.get("steps") or (["train", "index", "export"] if self.resume else list(STAGES))
        if any(s not in STAGES for s in steps):
            raise TrainError("Unknown training step.")
        self.steps = [s for s in STAGES if s in steps]
        self.memory = memory
        self.popen = popen
        self.clock = clock
        self.pm = cns_proto.ProgressMap([(s, w) for s, w in STAGE_WEIGHTS if s in self.steps])
        self.stop = threading.Event()
        self.detector = OvertrainDetector(req.get("patience") or OvertrainDetector.default_patience(self.total))
        self.tmp = self.work or os.path.join(self.paths["training"], ".tmp")
        self.step_epoch = {}
        self.parent = os.getppid()
        self.epochs_seen = 0
        self.start_epoch = 0
        if self.work:
            self._check_work()
        self.batch = None

    # -- helpers
    def _env(self):
        import cns_engines as eng
        tmp = self.tmp
        os.makedirs(tmp, exist_ok=True)
        env = eng._safe_env(os.path.dirname(self.paths["training"]), {
            "TMPDIR": tmp, "APPLIO_LOGS_DIR": self.paths["training"], "APPLIO_ROOT": self.paths["applio"],
            "PYTORCH_ENABLE_MPS_FALLBACK": "1", "OV_OFFLINE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "PYTHONUNBUFFERED": "1", "MPLCONFIGDIR": tmp, "XDG_CACHE_HOME": tmp,
            "NUMBA_CACHE_DIR": os.path.join(tmp, "numba")})
        return env

    def _should_stop(self):
        """SIGTERM, or the app that started us is gone (we were re-parented): the ~10 GB child must not live on."""
        return self.stop.is_set() or os.getppid() != self.parent

    def _argv(self, script_args):
        argv = [self.paths["python"]] + script_args
        if os.environ.get(NO_SANDBOX_ENV) == "1":
            return argv
        if not os.path.exists(SANDBOX_EXEC):
            raise TrainError("Can't start training safely: the macOS sandbox tool is missing.")
        roots = [self.paths["training"], self.tmp]
        return [SANDBOX_EXEC, "-p", train_profile(roots)] + argv

    def _run(self, stage, script_args, line_handler=None, watchdog_s=STAGE_WATCHDOG_S):
        wd = cns_proto.Watchdog(watchdog_s, lambda: None, clock=self.clock)

        def on_line(line):
            if stage != "train" or "step=" in line:
                wd.poke()
            if line_handler:
                line_handler(line)
            elif line.strip():
                self.emit.log(line[:400])

        argv = self._argv([os.path.join(self.paths["applio"], *script_args[0].split("/"))] + script_args[1:])
        code = run_child(argv, self._env(), self.paths["applio"], on_line, watchdog=wd, popen=self.popen,
                         should_stop=self._should_stop)
        if code != 0:
            raise TrainError("The %s step failed (exit code %s). Details are in the log." % (stage, code))

    # -- steps
    def preprocess(self):
        ds = self.req.get("dataset")
        if not ds or not os.path.isdir(os.path.expanduser(str(ds))):
            raise TrainError("Dataset folder not found.")
        ds = os.path.realpath(os.path.expanduser(str(ds)))
        self.emit.status("Preparing the recordings")
        os.makedirs(self.exp, exist_ok=True)
        cores = max(1, min(8, os.cpu_count() or 4))
        self._run("preprocess", ["rvc/train/preprocess/preprocess.py"] + preprocess_args(self.exp, ds, self.sr, cores))
        self.emit.progress(self.pm.at("preprocess", 1))

    def extract(self):
        self.emit.status("Extracting voice features")
        cores = max(1, min(8, os.cpu_count() or 4))
        self._run("extract", ["rvc/train/extract/extract.py"] +
                  extract_args(self.exp, self.f0, cores, self.gpu, self.sr, self.embedder))
        self.emit.progress(self.pm.at("extract", 1))

    def _pretrains(self):
        g = self.req.get("pretrain_g") or os.path.join(self.paths["weights"], "pretraineds", "hifi-gan",
                                                       "f0G%dk.pth" % (self.sr // 1000))
        d = self.req.get("pretrain_d") or os.path.join(self.paths["weights"], "pretraineds", "hifi-gan",
                                                       "f0D%dk.pth" % (self.sr // 1000))
        if not (os.path.isfile(g) and os.path.isfile(d)):
            raise TrainError("The %d kHz training base is not installed — install it in Engines." % (self.sr // 1000))
        return g, d

    def _check_resume(self):
        ck = checkpoints(self.exp)
        if self.resume:
            if not ck["G"] or not ck["D"]:
                raise TrainError(NOTHING_TO_CONTINUE)
            self.start_epoch = reached_epoch(self.exp, self.name)
            if self.total <= self.start_epoch:
                raise TrainError("Already trained for %d epochs — set a larger total to continue." % self.start_epoch)
        elif ck["G"] or ck["D"]:
            raise TrainError("A voice with this name already has training progress. Continue it, or pick another name.")

    def _batch(self):
        if self.req.get("batch_size"):
            return int(self.req["batch_size"])
        free = None
        try:
            free = self.memory() if self.memory else __import__("cns_engines").system_memory()["free_gb"]
            if isinstance(free, dict):
                free = free.get("free_gb")
        except Exception:  # noqa: BLE001
            free = None
        b = default_batch(free)
        if b == BATCH_TIGHT:
            self.emit.log("Not much free memory: training with batch 2 (slower, needs about 8 GB).")
        return b

    def train(self):
        self._check_resume()
        g, d = self._pretrains()
        self.batch = self._batch()
        frac = EpochFraction(self.total, self.start_epoch)
        self.emit.status("Training the voice" + (" (continuing from epoch %d)" % self.start_epoch if self.start_epoch else ""))
        args = train_args(self.name, self.save_every, self.total, g, d, self.gpu, self.batch, self.sr)

        def on_line(line):
            p = parse_progress(line)
            if p:
                epoch, _step, b, n = p
                if b is None:
                    self.step_epoch[_step] = epoch
                self.emit.progress(self.pm.at("train", frac.update(epoch, b, n)))
                if b is None:
                    self.emit.log(line[:400])
                    self._detect()
            elif line.strip():
                self.emit.log(line[:400])

        self._run("train", ["rvc/train/train.py"] + args, on_line, watchdog_s=TRAIN_WATCHDOG_S)
        self._detect()
        self.emit.progress(self.pm.at("train", 1))

    def _detect(self):
        rows = read_epoch_losses(os.path.join(self.exp, "eval"))
        by_step = {e[1]: e[0] for e in weights_files(self.exp, self.name)}
        by_step.update(self.step_epoch)
        new = rows[self.epochs_seen:]
        before = self.detector.state
        for i, (step, mel, gen) in enumerate(new):
            self.detector.update(by_step.get(step, self.start_epoch + self.epochs_seen + i + 1), mel, gen)
        self.epochs_seen += len(new)
        if new and (self.detector.state != before or self.detector.state != "improving"):
            rep = self.detector.report()
            if self.detector.state != "improving":
                self.emit.log("Overtraining check: %s. The best epoch so far is %s — you can stop and use it."
                              % (self.detector.state, rep["best_epoch"]))
            self.emit.emit("progress", value=self.pm.value, overtraining=rep)

    def index(self):
        self.emit.status("Building the voice index")
        self._run("index", ["rvc/train/process/extract_index.py", self.exp, self.index_algorithm])
        self.emit.progress(self.pm.at("index", 1))

    def _check_overwrite(self):
        if self.models_dir and not self.req.get("overwrite") and \
                os.path.exists(os.path.join(self.models_dir, self.name, self.name + ".pth")):
            raise TrainError("A voice named %s already exists. Pick another name, or allow replacing it." % self.name)

    def export(self):
        if not self.models_dir:
            raise TrainError("No models folder given.")
        self.emit.status("Saving the voice")
        use = self.req.get("use_epoch")
        if use is None and self.detector.state in ("plateau", "overtrained") and self.detector.best_epoch:
            use = self.detector.best_epoch
        pth = nearest_weights(self.exp, self.name, use) if use else None
        if pth is None:
            w = weights_files(self.exp, self.name)
            pth = w[-1][2] if w else None
        if pth is None:
            raise TrainError("Training produced no voice file.")
        m = _WEIGHTS_RE.match(os.path.basename(pth))
        out = os.path.join(self.models_dir, self.name)
        self._check_overwrite()
        os.makedirs(out, exist_ok=True)
        dst_pth = os.path.join(out, self.name + ".pth")
        shutil.copy2(pth, dst_pth)
        outputs = [dst_pth]
        idx = os.path.join(self.exp, self.name + ".index")
        if os.path.isfile(idx):
            shutil.copy2(idx, os.path.join(out, self.name + ".index"))
            outputs.append(os.path.join(out, self.name + ".index"))
        meta = {"name": self.name, "sample_rate": self.sr, "epoch": int(m.group("e")), "step": int(m.group("s")),
                "source": "trained", "has_index": len(outputs) == 2}
        with open(os.path.join(out, "meta.json"), "w") as f:
            json.dump(meta, f)
        self.emit.progress(self.pm.at("export", 1))
        return outputs, meta

    def _check_work(self):
        """The work folder is emptied at the end, so it must not be, or hold, anything we keep."""
        w = os.path.realpath(self.work)
        keep = [self.paths["training"], self.exp, self.paths["applio"], self.paths["weights"]]
        for extra in (self.req.get("dataset"), self.models_dir):
            if extra:
                keep.append(extra)
        for k in keep:
            k = os.path.realpath(os.path.expanduser(str(k)))
            if os.path.commonpath([w, k]) == w:
                raise TrainError("The work folder overlaps a folder that must be kept.")
        if w == os.path.realpath(os.path.expanduser("~")) or w == os.sep:
            raise TrainError("The work folder overlaps a folder that must be kept.")

    def clear_work(self):
        if self.work and os.path.isdir(self.work):
            for f in os.listdir(self.work):
                p = os.path.join(self.work, f)
                shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) and not os.path.islink(p) else _unlink(p)

    def run(self):
        outputs, meta = [], {}
        try:
            if "export" in self.steps:
                self._check_overwrite()
            for s in self.steps:
                if self.stop.is_set():
                    raise Stopped()
                if s == "export":
                    outputs, meta = self.export()
                else:
                    getattr(self, s)()
        finally:
            self.clear_work()
        return {"outputs": outputs, "best_epoch": self.detector.best_epoch, "overtraining": self.detector.report(),
                "batch_size": self.batch, "name": self.name, "meta": meta}


def _unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


# --------------------------------------------------------------------------------------------------------------- CLI

def cmd_run(req):
    tr = Trainer(req)

    def on_signal(_n, _f):
        tr.stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        cns_proto.result(**tr.run())
    except Stopped:
        cns_proto.status("Stopped. Training can be continued later.")
        return 143
    return 0


def cmd_review(req):
    folder = req.get("folder")
    if not folder:
        raise TrainError("Choose a dataset folder.")
    report = review_folder(folder, cns_proto.progress)
    cns_proto.result(report=report)
    return 0


def cmd_clean(req):
    paths = _engine_paths(dict(req, python=req.get("python") or "/usr/bin/true", applio=req.get("applio") or "/"))
    exp = os.path.join(paths["training"], slug(req.get("name")))
    cns_proto.result(freed_bytes=clean_checkpoints(exp))
    return 0


COMMANDS_CLI = {"run": cmd_run, "review": cmd_review, "clean": cmd_clean}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cns_train.py")
    ap.add_argument("command", choices=sorted(COMMANDS_CLI))
    args = ap.parse_args(sys.argv[1:] if argv is None else argv)
    cns_proto.install_stdout_guard()
    try:
        return COMMANDS_CLI[args.command](cns_proto.read_request())
    except (TrainError, cns_proto.ProtoError) as e:
        cns_proto.fail(str(e))
        return 1
    except Exception as e:  # noqa: BLE001  whatever else goes wrong must still reach the app as an error event
        cns_proto.fail("Training failed: %s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
