"""1) tune the stress judge on real speech, 2) measure the model stress accuracy per notation.

Research tool: WORKER=Sources/worker.py python tools/stress_eval.py plain,combining,upper 40 sample.wav
(needs real/meta.json from speech-uk/opentts and the test venv with mlx-audio, see stress_judge.py)."""
import itertools
import json
import os
import sys
import unicodedata

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import stress_judge as sj  # noqa: E402

worker, SR, VOWELS = sj.worker, sj.SR, sj.VOWELS


def nuclei(wav, n, sr=SR):
    """Per-syllable features [(log dur, log energy, pitch)] or None."""
    from scipy.signal import find_peaks
    env = sj.band_env(wav, sr)
    if len(env) < 8:
        return None
    hop = 0.005
    f0 = worker.track_f0(wav, sr, 0.01)
    f0i = np.repeat(f0, 2)[: len(env)] if len(f0) else np.zeros(len(env))
    f0i = np.pad(f0i, (0, max(0, len(env) - len(f0i))))
    peaks = np.zeros(0, dtype=int)
    for prom in (0.25, 0.15, 0.08, 0.04, 0.02):
        peaks, props = find_peaks(env, distance=int(0.055 / hop), prominence=env.max() * prom)
        if len(peaks) >= n:
            break
    if len(peaks) < n:
        return None
    if len(peaks) > n:
        peaks = np.sort(peaks[np.argsort(props["prominences"])[::-1][:n]])
    bounds = [0] + [int(np.argmin(env[a:b]) + a) for a, b in zip(peaks[:-1], peaks[1:])] + [len(env)]
    voiced = f0i[f0i > 0]
    med = float(np.median(voiced)) if len(voiced) else 0.0
    feats = []
    for k, p in enumerate(peaks):
        a, b = bounds[k], bounds[k + 1]
        half = env[p] * 0.5
        lo, hi = p, p
        while lo > a and env[lo] > half:
            lo -= 1
        while hi < b - 1 and env[hi] > half:
            hi += 1
        dur = (hi - lo + 1) * hop
        energy = float((env[lo:hi + 1] ** 2).sum()) * hop
        seg = f0i[lo:hi + 1]
        fmax = float(seg[seg > 0].max()) if (seg > 0).any() and med else med
        feats.append((np.log(dur), 0.5 * np.log(energy), np.log(fmax / med) if med else 0.0))
    return feats


def decide(feats, w):
    return int(np.argmax([w[0] * d + w[1] * e + w[2] * p for d, e, p in feats])) + 1


def word_feats(stt, wav, stressed_text, plain_text):
    ref = sj.stressed_words(stressed_text)
    if not ref:
        return []
    heard = sj.align(stt, wav, plain_text)
    out = []
    for i, k in sj.match(ref, heard):
        word, truth = ref[i]
        _, s, e = heard[k]
        a, b = max(0, int((s - 0.02) * SR)), min(len(wav), int((e + 0.02) * SR))
        if b - a < SR * 0.08:
            continue
        f = nuclei(wav[a:b], sum(c in VOWELS for c in word))
        if f:
            out.append({"word": word, "truth": truth, "feats": f})
    return out


GRID = [w for w in itertools.product([0, 0.5, 1, 1.5, 2], repeat=3) if any(w)]


def tune(rows):
    best = max(GRID, key=lambda w: sum(decide(r["feats"], w) == r["truth"] for r in rows))
    acc = sum(decide(r["feats"], best) == r["truth"] for r in rows) / len(rows)
    return best, acc


def real_rows(stt):
    cache = "real/feats.json"
    if os.path.exists(cache):
        return json.load(open(cache))
    rows = []
    for m in json.load(open("real/meta.json")):
        rows += word_feats(stt, worker.load_mono(m["wav"]), m["stressed"], m["text"])
    json.dump(rows, open(cache, "w"))
    return rows


def mark_text(stressed_text, how):
    """The ground-truth marks rewritten in a notation: ви́шивка → вишИвка, в+ишивка, …"""
    t = unicodedata.normalize("NFC", stressed_text).replace("´", "́")
    if how == "plain":
        return t.replace("́", "")
    if how == "combining":
        return t
    out = []
    for i, c in enumerate(t):
        if c == "́":
            continue
        nxt = t[i + 1] if i + 1 < len(t) else ""
        if nxt == "́":
            if how == "upper":
                out.append(c.upper())
            elif how == "plus":
                out.append("+" + c)
            elif how == "acute":
                out.append(c + "´")
            elif how == "apos":
                out.append(c + "'")
            elif how == "grave":
                out.append(c + "̀")
            else:
                raise ValueError(how)
        else:
            out.append(c)
    return "".join(out)


OKSAMYT = ["Оксамит на столі.", "Вона купила оксамит.", "Червоний оксамит блищить.", "Оксамит, шовк і жакард."]
OKSAMYT_S = ["Оксами́т на столі́.", "Вона́ купи́ла оксами́т.", "Черво́ний оксами́т блищи́ть.", "Оксами́т, шовк і жака́рд."]


def main():
    hows = sys.argv[1].split(",") if len(sys.argv) > 1 else ["plain", "combining", "upper", "plus", "acute"]
    n_sent = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    voice = sys.argv[3] if len(sys.argv) > 3 else None   # path to a sample wav (+ .txt) for a cloned voice
    stt = worker.ensure_stt(sj.ASR, False, 16)
    rows = real_rows(stt)
    w, acc = tune(rows)
    print(f"judge on real speech: weights dur/energy/pitch = {w}, accuracy {acc:.0%} on {len(rows)} words", flush=True)

    tts = worker.ensure_tts({"path": sj.MODEL, "bits": 16})
    prompt = None
    if voice:
        tokens = worker.build_prompt(tts, voice, open(os.path.splitext(voice)[0] + ".txt").read().strip())
        prompt = {"tokens": tokens, "ref_text": open(os.path.splitext(voice)[0] + ".txt").read().strip()}
    meta = json.load(open("real/meta.json"))[:n_sent]
    meta += [{"text": a, "stressed": b, "oks": True} for a, b in zip(OKSAMYT, OKSAMYT_S)]
    for how in hows:
        hit = tot = 0
        oks = []
        for i, m in enumerate(meta):
            text = mark_text(m["stressed"], how)
            wav = worker._speak(tts, text, "uk", prompt, {}, seed=100 + i, stress=False)
            rows = word_feats(stt, wav, m["stressed"], m["text"])
            for r in rows:
                got = decide(r["feats"], w)
                if m.get("oks") and r["word"].startswith("оксамит"):
                    oks.append(got)
                    continue
                tot += 1
                hit += got == r["truth"]
        print(f"{how:10s} model stress right {hit}/{tot} = {hit / max(1, tot):.0%}   оксамит→ syllable {oks} (truth 3)", flush=True)


if __name__ == "__main__":
    main()
