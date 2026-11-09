"""Generate spike test audio with macOS `say` + afconvert (+ numpy music bed).

usage: gen_audio.py OUT_DIR
Creates in OUT_DIR:
  dataset/*.wav   ~2 min of English speech (Samantha + Daniel + Karen mixed? -> single voice Samantha, 40 s sentences)
  ref10.wav       ~10 s speech (inference input, 16-bit mono 44.1k)
  speech30.wav    ~30 s speech
  mix.wav         speech30 + synthetic music bed (separation test)
"""
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

out = sys.argv[1]
os.makedirs(os.path.join(out, "dataset"), exist_ok=True)

SENTENCES = [
    "The quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills.",
    "Nobody expected the old library to hold so many forgotten stories, but every shelf seemed to whisper another secret.",
    "She walked along the river, thinking about the long journey ahead and the people she would meet on the way.",
    "A good voice carries warmth, patience and a little bit of mystery, and that is what listeners remember.",
    "Technology changes quickly, yet a simple conversation between two friends still feels like the most natural thing in the world.",
    "When the rain finally stopped, the streets filled with the smell of fresh bread and wet stone.",
    "He opened the window, took a deep breath, and decided that today would be a day for new beginnings.",
    "The train left the station exactly on time, carrying travelers, letters, and a few small dreams toward the coast.",
    "In the evening the village lights came on one by one, and the children gathered to listen to the oldest storyteller.",
    "Please remember to check the weather forecast before you leave, because the mountain road can be slippery after midnight.",
    "Music has a way of turning an ordinary afternoon into something worth keeping in your memory for years to come.",
    "The engineer explained the plan slowly, drawing each step on the board until everyone in the room understood.",
    "We could hear the waves long before we saw the sea, a steady rhythm that made the whole night feel calm.",
    "Learning a new language takes time, patience and a lot of practice, but every small success is a reward.",
    "The market was full of colors: red peppers, golden apples, green herbs, and baskets of warm bread.",
    "After dinner they sat on the porch, sharing stories about school, travel, work and the funny things that happen.",
]


def say(text, voice, path_wav, rate=165):
    aiff = path_wav + ".aiff"
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "1", aiff, path_wav], check=True)
    os.remove(aiff)
    a, sr = sf.read(path_wav)
    return a, sr


total = 0.0
for i, s in enumerate(SENTENCES):
    a, sr = say(s, "Samantha", os.path.join(out, "dataset", f"s{i:02d}.wav"))
    total += len(a) / sr
print("dataset seconds:", round(total, 1))

# 10 s inference input
txt = " ".join(SENTENCES[:2]) + " " + SENTENCES[3][:40]
a, sr = say(txt, "Samantha", os.path.join(out, "ref10.wav"))
n = int(10 * sr)
a = a[:n]
sf.write(os.path.join(out, "ref10.wav"), a, sr, subtype="PCM_16")
print("ref10 seconds:", len(a) / sr)

# 30 s speech + music bed
txt = " ".join(SENTENCES[4:9])
a, sr = say(txt, "Daniel", os.path.join(out, "speech30.wav"))
a = a[: int(30 * sr)]
sf.write(os.path.join(out, "speech30.wav"), a, sr, subtype="PCM_16")
t = np.arange(len(a)) / sr
rng = np.random.default_rng(0)
music = np.zeros_like(t)
chords = [(220, 277.2, 329.6), (196, 246.9, 293.7), (174.6, 220, 261.6), (196, 246.9, 392)]
for k in range(len(t) // (sr * 2) + 1):
    f0 = chords[k % 4]
    s0, s1 = k * 2 * sr, min(len(t), (k + 1) * 2 * sr)
    tt = t[s0:s1]
    for f in f0:
        music[s0:s1] += 0.15 * np.sin(2 * np.pi * f * tt) + 0.05 * np.sin(2 * np.pi * 2 * f * tt)
beat = (np.sin(2 * np.pi * 60 * t) * np.exp(-((t % 0.5) * 18))) * 0.5
hat = rng.standard_normal(len(t)) * np.exp(-(((t + 0.25) % 0.5) * 60)) * 0.08
music = music + beat + hat
music = music / np.abs(music).max() * 0.5
mix = a / (np.abs(a).max() + 1e-9) * 0.6 + music
mix = mix / np.abs(mix).max() * 0.9
sf.write(os.path.join(out, "mix.wav"), mix, sr, subtype="PCM_16")
sf.write(os.path.join(out, "music_only.wav"), music, sr, subtype="PCM_16")
print("done", len(a) / sr)
