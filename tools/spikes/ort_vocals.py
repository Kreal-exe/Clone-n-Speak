"""Vocal extraction with an UVR MDX-Net ONNX model through onnxruntime + numpy only (no torch).

usage: python -I ort_vocals.py MODEL.onnx MIX.wav OUT_VOCALS.wav [PROVIDER cpu|coreml] [REFERENCE_SPEECH.wav]
Params of Kim_Vocal_2 (UVR model_data.json): n_fft 7680, dim_f 3072, dim_t 256 (2**8), hop 1024, compensate 1.009.
Prints wall time, realtime factor and (with a reference) SI-SDR of the result against the clean speech.
"""
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf
from scipy import fft as sfft
from scipy.signal import resample_poly

model, mix_path, out_path = sys.argv[1:4]
provider = sys.argv[4] if len(sys.argv) > 4 else "cpu"
ref_path = sys.argv[5] if len(sys.argv) > 5 else None

N_FFT, DIM_F, DIM_T, HOP, COMP = 7680, 3072, 256, 1024, 1.009
CHUNK = HOP * (DIM_T - 1)
TRIM = N_FFT // 2
GEN = CHUNK - N_FFT
WIN = np.hanning(N_FFT + 1)[:-1].astype(np.float32)  # periodic hann, as torch.hann_window


def stft(x):  # x: (T,) -> (freq, frames) complex, center=True reflect pad
    x = np.pad(x, (N_FFT // 2, N_FFT // 2), mode="reflect")
    n = 1 + (len(x) - N_FFT) // HOP
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n)[:, None]
    return sfft.rfft(x[idx] * WIN, axis=1).T


def istft(spec, length):  # spec: (freq, frames)
    frames = sfft.irfft(spec.T, n=N_FFT, axis=1) * WIN
    n = frames.shape[0]
    out = np.zeros(N_FFT + HOP * (n - 1), dtype=np.float32)
    norm = np.zeros_like(out)
    for i in range(n):
        out[i * HOP : i * HOP + N_FFT] += frames[i]
        norm[i * HOP : i * HOP + N_FFT] += WIN**2
    out = out / np.maximum(norm, 1e-8)
    return out[N_FFT // 2 : N_FFT // 2 + length]


audio, sr = sf.read(mix_path, dtype="float32")
if audio.ndim == 1:
    audio = np.stack([audio, audio], 1)
if sr != 44100:
    audio = resample_poly(audio, 44100, sr, axis=0).astype(np.float32)
mix = audio.T  # (2, T)
n_sample = mix.shape[1]

providers = ["CPUExecutionProvider"] if provider == "cpu" else ["CoreMLExecutionProvider", "CPUExecutionProvider"]
t0 = time.time()
sess = ort.InferenceSession(model, providers=providers)
inp = sess.get_inputs()[0]
print("onnx input", inp.name, inp.shape, "providers", sess.get_providers(), "load s", round(time.time() - t0, 2))

pad = GEN - (n_sample % GEN)
mix_p = np.concatenate([np.zeros((2, TRIM), np.float32), mix, np.zeros((2, pad + TRIM), np.float32)], 1)
out = np.zeros((2, n_sample + pad), np.float32)
t1 = time.time()
for i in range(0, n_sample + pad, GEN):
    chunk = mix_p[:, i : i + CHUNK]
    if chunk.shape[1] < CHUNK:
        chunk = np.pad(chunk, ((0, 0), (0, CHUNK - chunk.shape[1])))
    specs = [stft(chunk[c]) for c in range(2)]  # each (3841, 256)
    x = np.stack([np.stack([s.real, s.imag]) for s in specs]).reshape(4, -1, DIM_T)[:, :DIM_F]  # (4,F,T)
    y = sess.run(None, {inp.name: x[None].astype(np.float32)})[0][0] * COMP  # (4,F,T)
    y = np.pad(y, ((0, 0), (0, N_FFT // 2 + 1 - DIM_F), (0, 0))).reshape(2, 2, N_FFT // 2 + 1, DIM_T)
    for c in range(2):
        # keep only the centre GEN samples of each chunk (edges carry STFT boundary artifacts)
        out[c, i : i + GEN] = istft(y[c, 0] + 1j * y[c, 1], CHUNK)[TRIM : TRIM + GEN]
voc = out[:, :n_sample]
dt = time.time() - t1
print(f"separation {dt:.1f} s for {n_sample / 44100:.1f} s audio, RTF {dt / (n_sample / 44100):.2f}")
sf.write(out_path, voc.T, 44100, subtype="PCM_16")
if ref_path:
    ref, rsr = sf.read(ref_path, dtype="float32")
    ref = ref if ref.ndim == 1 else ref.mean(1)
    est = voc.mean(0)[: len(ref)]
    ref = ref[: len(est)]
    a = (est @ ref) / (ref @ ref + 1e-9)
    tgt = a * ref
    sdr = 10 * np.log10((tgt @ tgt + 1e-9) / (((est - tgt) ** 2).sum() + 1e-9))
    mixm = mix.mean(0)[: len(ref)]
    a2 = (mixm @ ref) / (ref @ ref + 1e-9)
    sdr_mix = 10 * np.log10(((a2 * ref) @ (a2 * ref) + 1e-9) / (((mixm - a2 * ref) ** 2).sum() + 1e-9))
    print(f"SI-SDR vs clean speech: mix {sdr_mix:.1f} dB -> separated {sdr:.1f} dB")
