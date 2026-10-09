"""Stress judge: which syllable of a spoken word is stressed, from the audio.

Words are located with Whisper word timestamps; inside a word the vowel nuclei are energy peaks of the
sonorant band, and the stressed one is the longest / loudest / highest. Validated on real speech
(speech-uk/opentts, whose transcripts carry stress marks)."""
import glob
import importlib.util
import json
import os
import re
import sys
import unicodedata

import numpy as np

_spec = importlib.util.spec_from_file_location("worker", os.environ["WORKER"])
worker = importlib.util.module_from_spec(_spec)
_stdout = sys.stdout
_spec.loader.exec_module(worker)
sys.stdout = _stdout
worker.emit = lambda *a, **k: None
worker.status = lambda *a, **k: None

SR = 24000
VOWELS = "аеєиіїоуюя"
MODEL = glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--mlx-community--OmniVoice-bf16/snapshots/*"))[0]
ASR = glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-asr-fp16/snapshots/*"))[0]


def norm_word(w):
    w = unicodedata.normalize("NFC", w.lower()).replace("́", "").replace("´", "")
    return re.sub(r"[^а-яіїєґ']", "", w.replace("’", "'").replace("ʼ", "'"))


def stressed_words(stressed_text):
    """[(plain word, 1-based stressed syllable)] for words with ≥2 vowels and exactly one mark."""
    out = []
    for tok in stressed_text.split():
        tok = unicodedata.normalize("NFD", tok)
        plain = norm_word(tok)
        marks = [i for i, c in enumerate(tok) if c in "́´"]
        vs = [i for i, c in enumerate(plain) if c in VOWELS]
        if len(vs) < 2 or len(marks) != 1:
            continue
        # vowel just before the mark
        before = norm_word(tok[: marks[0]])
        n_v = sum(c in VOWELS for c in before)
        if n_v == 0:
            continue
        out.append((plain, n_v))
    return out


def band_env(wav, sr=SR, hop=0.005):
    from scipy.ndimage import uniform_filter1d
    from scipy.signal import butter, sosfiltfilt
    sos = butter(4, [250, 2500], btype="band", fs=sr, output="sos")
    x = sosfiltfilt(sos, np.asarray(wav, dtype=np.float64))
    h = int(sr * hop)
    n = len(x) // h
    if n < 4:
        return np.zeros(0)
    e = np.sqrt((x[: n * h].reshape(n, h) ** 2).mean(axis=1) + 1e-12)
    return uniform_filter1d(e, 5)


def judge(wav, n, sr=SR):
    """1-based stressed syllable among n, or 0 when the nuclei cannot be told apart."""
    from scipy.signal import find_peaks
    env = band_env(wav, sr)
    if len(env) < 8:
        return 0
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
        return 0
    if len(peaks) > n:
        order = np.argsort(props["prominences"])[::-1][:n]
        peaks = np.sort(peaks[order])
    bounds = [0] + [int(np.argmin(env[a:b]) + a) for a, b in zip(peaks[:-1], peaks[1:])] + [len(env)]
    voiced = f0i[f0i > 0]
    med = float(np.median(voiced)) if len(voiced) else 0.0
    scores = []
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
        pitch = np.log(fmax / med) if med else 0.0
        scores.append(1.0 * np.log(dur) + 0.5 * np.log(energy) + 1.5 * pitch)
    return int(np.argmax(scores)) + 1


def align(stt, wav, text=None):
    """Whisper words with times for a 24 kHz recording."""
    res = stt.generate(worker._resample_16k(wav), language="uk", word_timestamps=True, temperature=0.0,
                       initial_prompt=text)
    words = []
    for s in res.segments or []:
        for w in s.get("words", []):
            words.append((norm_word(w["word"]), float(w["start"]), float(w["end"])))
    return [w for w in words if w[0]]


def match(ref_words, heard):
    """Pairs (ref index, heard index) in order, by equal normalized words."""
    pairs, j = [], 0
    for i, (w, _) in enumerate(ref_words):
        for k in range(j, len(heard)):
            if heard[k][0] == w:
                pairs.append((i, k))
                j = k + 1
                break
    return pairs


def score_sentence(stt, wav, stressed_text, plain_text=None):
    """[(word, truth, judged)] for the stressed words Whisper located."""
    ref = stressed_words(stressed_text)
    if not ref:
        return []
    heard = align(stt, wav, plain_text)
    out = []
    for i, k in match(ref, heard):
        word, truth = ref[i]
        _, s, e = heard[k]
        a, b = max(0, int((s - 0.02) * SR)), min(len(wav), int((e + 0.02) * SR))
        if b - a < SR * 0.08:
            continue
        n = sum(c in VOWELS for c in word)
        out.append((word, truth, judge(wav[a:b], n)))
    return out


def validate_real():
    meta = json.load(open("real/meta.json"))
    stt = worker.ensure_stt(ASR, False, 16)
    hit = tot = unsure = 0
    per_len = {}
    for m in meta:
        wav = worker.load_mono(m["wav"])
        for word, truth, got in score_sentence(stt, wav, m["stressed"], m["text"]):
            n = sum(c in VOWELS for c in word)
            d = per_len.setdefault(n, [0, 0])
            if got == 0:
                unsure += 1
                continue
            tot += 1
            d[1] += 1
            if got == truth:
                hit += 1
                d[0] += 1
    print(f"real speech: {hit}/{tot} = {hit / max(1, tot):.0%} judged right, {unsure} unsure; by syllables: "
          + " ".join(f"{n}:{h}/{t}" for n, (h, t) in sorted(per_len.items())), flush=True)


if __name__ == "__main__":
    validate_real()
