"""Synthetic audio for the audio tests (numpy / scipy only). Import with `from audio_fixtures import ...`."""
import numpy as np

SR = 24000


def tone(f, seconds, sr=SR, amp=0.3):
    t = np.arange(int(sr * seconds)) / sr
    return (amp * np.sin(2 * np.pi * f * t)).astype(np.float32)


def voice(seconds, f0=120.0, vibrato=0.0, sr=SR):
    """A buzzy, voice-like tone: harmonics of f0, optionally gliding +-`vibrato` semitones twice a second."""
    t = np.arange(int(sr * seconds)) / sr
    freq = f0 * 2 ** (vibrato * np.sin(2 * np.pi * 2 * t) / 12)
    phase = 2 * np.pi * np.cumsum(freq) / sr
    return (0.1 * sum(np.sin(k * phase) / k for k in range(1, 9))).astype(np.float32)


def speechlike(seconds, sr=SR):
    """Voiced chunks of 0.4 s with 0.2 s pauses over -55 dB noise."""
    rng = np.random.default_rng(7)
    n = int(sr * seconds)
    out = (10 ** (-55 / 20) * rng.standard_normal(n)).astype(np.float32)
    pos, k = 0, 0
    while pos < n:
        chunk = voice(0.4, f0=110 + 15 * (k % 4), vibrato=1.0, sr=sr)
        end = min(n, pos + len(chunk))
        out[pos:end] += chunk[:end - pos]
        pos = end + int(sr * 0.2)
        k += 1
    return out


def vowel(f1, f2, f0=120, seconds=1.5, sr=SR):
    """Harmonics of f0 up to 6 kHz shaped by two formants at f1 and f2."""
    t = np.arange(int(sr * seconds)) / sr
    out = np.zeros_like(t)
    for k in range(1, int(6000 // f0) + 1):
        f = k * f0
        amp = np.exp(-((f - f1) / 150) ** 2) + 0.6 * np.exp(-((f - f2) / 250) ** 2) + 0.02
        out += amp * np.sin(2 * np.pi * f * t)
    return (0.3 * out / np.abs(out).max()).astype(np.float32)


def write_wav(path, wav, sr, subtype="pcm16"):
    """Writes a WAV with scipy: pcm16, pcm24 (hand-packed), pcm32 or float32. wav is (n,) or (n, ch) in [-1, 1]."""
    from scipy.io import wavfile
    x = np.asarray(wav, dtype=np.float64)
    if subtype == "float32":
        wavfile.write(path, sr, x.astype(np.float32))
    elif subtype == "pcm16":
        wavfile.write(path, sr, (np.clip(x, -1, 1) * 32767).round().astype(np.int16))
    elif subtype == "pcm32":
        wavfile.write(path, sr, (np.clip(x, -1, 1) * 2147483647).round().astype(np.int32))
    elif subtype == "pcm24":
        import wave
        ints = (np.clip(x, -1, 1) * 8388607).round().astype("<i4")
        raw = ints.reshape(-1).view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1 if x.ndim == 1 else x.shape[1])
            wf.setsampwidth(3)
            wf.setframerate(sr)
            wf.writeframes(raw)
    else:
        raise ValueError(subtype)


def rms_db(x):
    x = np.asarray(x, dtype=np.float64)
    return float(20 * np.log10(np.sqrt((x ** 2).mean() + 1e-12)))


def peak_freq(x, sr=SR):
    x = np.asarray(x, dtype=np.float64)
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float(np.fft.rfftfreq(len(x), 1 / sr)[int(np.argmax(spec))])
