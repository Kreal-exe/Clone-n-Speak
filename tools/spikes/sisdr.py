"""SI-SDR of an estimate against a clean reference (scale-invariant), for the separation spike.

usage: python -I sisdr.py REFERENCE.wav ESTIMATE.(wav|flac) [MIX.wav]
"""
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly


def load(p):
    a, sr = sf.read(p, dtype="float32")
    a = a if a.ndim == 1 else a.mean(1)
    return resample_poly(a, 44100, sr).astype(np.float32) if sr != 44100 else a


def si_sdr(est, ref):
    n = min(len(est), len(ref))
    est, ref = est[:n], ref[:n]
    t = (est @ ref) / (ref @ ref + 1e-9) * ref
    return 10 * np.log10((t @ t + 1e-9) / (((est - t) ** 2).sum() + 1e-9))


ref, est = load(sys.argv[1]), load(sys.argv[2])
print(f"SI-SDR estimate vs reference: {si_sdr(est, ref):.1f} dB")
if len(sys.argv) > 3:
    print(f"SI-SDR mix vs reference:      {si_sdr(load(sys.argv[3]), ref):.1f} dB")
