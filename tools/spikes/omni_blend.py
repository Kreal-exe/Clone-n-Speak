#!/usr/bin/env python
"""Experiment (task 7.12): can two cloned OmniVoice voices be blended through Seed-VC?

Hypothesis: speech made by OmniVoice in voice A is passed through Seed-VC with a *reference mix* as the target: a sample
built from alternating chunks of A's and B's samples in the proportion `ratio` (up to 25 s). Seed-VC averages the timbre
over its reference, so the result should move smoothly from A (ratio 1) to B (ratio 0).

Runs on the MAIN runtime python (the app's own venv, where worker.likeness and Whisper live):

    PY="$HOME/Library/Application Support/Clone'n'Speak/runtime/.venv/bin/python"
    "$PY" tools/spikes/omni_blend.py reference --pairs pairs.json --out /tmp/blend      # stage 1: no OmniVoice needed
    "$PY" tools/spikes/omni_blend.py full --pairs pairs.json --sources /tmp/src --out /tmp/blend

pairs.json: [{"name": "mm", "a": "<A reference.wav>", "b": "<B reference.wav>"}, ...]  (m/m, f/f, m/f).
--sources: <name>-en.wav and <name>-uk.wav, the phrase spoken by OmniVoice in voice A (the app makes them; this script
does not load OmniVoice). `full` needs those files and the pro engine (Seed-VC); without them it says "not measured".

Stage 1 (`reference`) measures only the reference mix: ECAPA similarity of the mix to A and to B per ratio. It is the
necessary condition of the idea, because Seed-VC cannot be more like B than its reference is.

Go criteria (plan 7.12): (1) ECAPA likeness to A falls and to B rises with the ratio (tolerance 0.02) and at 0.5 both are
>= 0.35 x (likeness of the voice to itself); (2) Whisper CER not worse than the baseline by more than 3 points;
(3) a human listens: the middle points sound like one person.
"""
import argparse
import json
import os
import subprocess
import sys
import wave

import numpy as np

SR = 24000
RATIOS = (0.0, 0.25, 0.5, 0.75, 1.0)   # share of voice A in the mix
CHUNK_S = 2.0
MAX_S = 25.0
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Sources")


def read_wav(path, sr=SR):
    """Mono float32 at `sr` (wave module for PCM, scipy for resampling)."""
    from scipy.io import wavfile
    from scipy.signal import resample_poly
    from math import gcd
    rate, data = wavfile.read(path)
    if data.dtype.kind in "iu":
        data = data.astype(np.float32) / float(np.iinfo(data.dtype).max)
    data = data.astype(np.float32)
    if data.ndim > 1:
        data = data.mean(axis=1)
    if rate != sr:
        g = gcd(rate, sr)
        data = resample_poly(data, sr // g, rate // g).astype(np.float32)
    return data


def write_wav(path, x, sr=SR):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def mix_reference(a, b, ratio, sr=SR, chunk_s=CHUNK_S, max_s=MAX_S):
    """Alternating chunks of A and B: per period of 10 chunks round(ratio * 10) come from A, the rest from B, spread
    evenly (Bresenham), each chunk is taken from the running position of its own sample (wrapping) with a 20 ms fade so
    the joins do not click. ratio 0 = only B, ratio 1 = only A. Length = min(max_s, ...)."""
    if not 0.0 <= ratio <= 1.0:
        raise ValueError("ratio must be between 0 and 1")
    n = int(chunk_s * sr)
    fade = int(0.02 * sr)
    total = int(max_s / chunk_s)
    pos = {"a": 0, "b": 0}
    src = {"a": a, "b": b}
    acc, out = 0.0, []
    for _ in range(total):
        acc += ratio
        pick = "a" if acc >= 1.0 - 1e-9 else "b"
        if pick == "a":
            acc -= 1.0
        s = src[pick]
        idx = (pos[pick] + np.arange(n)) % len(s)
        pos[pick] = (pos[pick] + n) % len(s)
        piece = s[idx].copy()
        piece[:fade] *= np.linspace(0, 1, fade)
        piece[-fade:] *= np.linspace(1, 0, fade)
        out.append(piece)
    return np.concatenate(out).astype(np.float32)


def monotone(values, increasing, tol=0.02):
    """True when each step goes the right way, allowing a dip of `tol`."""
    for x, y in zip(values, values[1:]):
        if (y - x if increasing else x - y) < -tol:
            return False
    return True


def verdict_for_pair(like_a, like_b, self_like, cer, cer_base):
    """The plan's criteria (1) and (2) for one pair/language. like_a / like_b: lists per RATIOS (share of A, ascending)."""
    c1_dir = monotone(like_a, True) and monotone(like_b, False)   # likeness to A rises with the share of A
    mid = RATIOS.index(0.5)
    c1_mid = like_a[mid] >= 0.35 * self_like and like_b[mid] >= 0.35 * self_like
    c2 = cer is None or cer_base is None or max(cer) - cer_base <= 0.03
    return {"monotone": c1_dir, "middle_ok": c1_mid, "cer_ok": c2, "pass": bool(c1_dir and c1_mid and c2)}


def _worker():
    sys.path.insert(0, SOURCES)
    import worker   # noqa: E402  (loads MLX; stdout is not used here)
    return worker


def voice_print_of(path):
    return _worker().voice_print(read_wav(path))


def cosine(u, v):
    return float(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-9))


def cmd_reference(args):
    pairs = json.load(open(args.pairs))
    os.makedirs(args.out, exist_ok=True)
    report = []
    for p in pairs:
        a, b = read_wav(p["a"]), read_wav(p["b"])
        pa, pb = voice_print_of(p["a"]), voice_print_of(p["b"])
        # a voice against itself: first half vs second half of the sample
        half = len(a) // 2
        w = _worker()
        self_like = cosine(w.voice_print(a[:half]), w.voice_print(a[half:]))
        la, lb = [], []
        for r in RATIOS:
            ref = mix_reference(a, b, r)
            path = os.path.join(args.out, "%s-ref-%03d.wav" % (p["name"], int(r * 100)))
            write_wav(path, ref)
            e = w.voice_print(ref)
            la.append(round(cosine(e, pa), 3))
            lb.append(round(cosine(e, pb), 3))
        v = verdict_for_pair(la, lb, self_like, None, None)
        report.append({"pair": p["name"], "ab_likeness": round(cosine(pa, pb), 3), "self_likeness": round(self_like, 3),
                       "like_a": la, "like_b": lb, "ratios_share_of_a": list(RATIOS), **v})
        print(json.dumps(report[-1], ensure_ascii=False))
    json.dump(report, open(os.path.join(args.out, "reference-report.json"), "w"), indent=1)


def seedvc_convert(source, target, out_dir, work):
    """Seed-VC through cns_seedvc in the pro environment (the engine root is the app's)."""
    sup = os.path.expanduser("~/Library/Application Support/Clone'n'Speak")
    py = os.path.join(sup, "engines", "pro", ".venv", "bin", "python")
    if not os.path.isfile(py):
        raise SystemExit("not measured: the pro engine is not installed")
    req = {"input": source, "target": target, "outputs_dir": out_dir, "work_dir": work, "engine_root": os.path.join(sup, "engines")}
    r = subprocess.run([py, "-s", os.path.join(SOURCES, "cns_seedvc.py"), "convert"], input=json.dumps(req), text=True,
                       capture_output=True, timeout=3600)
    for line in r.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("event") == "result":
            return ev["data"]["outputs"][0]
        if ev.get("event") == "error":
            raise SystemExit("Seed-VC failed: %s" % ev.get("msg"))
    raise SystemExit("Seed-VC gave no result")


def cmd_full(args):
    pairs = json.load(open(args.pairs))
    os.makedirs(args.out, exist_ok=True)
    w = _worker()
    report = []
    for p in pairs:
        a, b = read_wav(p["a"]), read_wav(p["b"])
        pa, pb = w.voice_print(a), w.voice_print(b)
        half = len(a) // 2
        self_like = cosine(w.voice_print(a[:half]), w.voice_print(a[half:]))
        for lang in ("en", "uk"):
            src = os.path.join(args.sources, "%s-%s.wav" % (p["name"], lang))
            if not os.path.isfile(src):
                print("not measured: %s is missing (speak the phrase with OmniVoice in voice A first)" % src)
                continue
            la, lb = [], []
            for r in RATIOS:
                ref = os.path.join(args.out, "%s-ref-%03d.wav" % (p["name"], int(r * 100)))
                write_wav(ref, mix_reference(a, b, r))
                out = seedvc_convert(src, ref, args.out, os.path.join(args.out, "work"))
                e = w.voice_print(read_wav(out))
                la.append(round(cosine(e, pa), 3))
                lb.append(round(cosine(e, pb), 3))
            v = verdict_for_pair(la, lb, self_like, None, None)   # CER: see the note, Whisper is run by the caller
            report.append({"pair": p["name"], "lang": lang, "like_a": la, "like_b": lb, "self_likeness": round(self_like, 3), **v})
            print(json.dumps(report[-1], ensure_ascii=False))
    json.dump(report, open(os.path.join(args.out, "full-report.json"), "w"), indent=1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("reference", cmd_reference), ("full", cmd_full)):
        s = sub.add_parser(name)
        s.add_argument("--pairs", required=True)
        s.add_argument("--out", required=True)
        if name == "full":
            s.add_argument("--sources", required=True)
        s.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
