"""Applio realtime chain latency: per-block processing time of VoiceChanger.on_request.

usage: python -I rt_bench.py APPLIO_DIR DEVICE(mps|cpu) INPUT_WAV PTH INDEX BLOCK_SEC EXTRA_SEC CROSSFADE_SEC [F0_METHOD]
Latency estimate = block duration (must be collected before processing) + processing ms
(+ audio device I/O, not measured here: no microphone use in the spike).
"""
import os
import sys
import time

import numpy as np

applio, device, inp, pth, index, block_s, extra_s, xf_s = sys.argv[1:9]
f0 = sys.argv[9] if len(sys.argv) > 9 else "rmvpe"
block_s, extra_s, xf_s = float(block_s), float(extra_s), float(xf_s)
os.chdir(applio)
sys.path.insert(0, applio)
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import resource  # noqa: E402

import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from scipy.signal import resample_poly  # noqa: E402

if device == "cpu":
    torch.backends.mps.is_available = lambda: False
from rvc.realtime.core import VoiceChanger  # noqa: E402

a, sr = sf.read(inp)
if a.ndim > 1:
    a = a.mean(1)
a48 = resample_poly(a, 48000, sr).astype(np.float32)
a48 = np.tile(a48, 2)  # ~20 s
block = int(round(block_s * 48000 / 480)) * 480

t0 = time.time()
vc = VoiceChanger(
    block_frame=block,
    cross_fade_overlap_size=xf_s,
    extra_convert_size=extra_s,
    model_path=pth,
    index_path=index,
    f0_method=f0,
    embedder_model="contentvec",
    silent_threshold=-60,  # default 0 dB gates everything as silence
    device=device,
)
print("load s", round(time.time() - t0, 2), "device", vc.device, "block", block)
w = vc.warmup(index_rate=0.3, protect=0.33)
print("warmup max ms (last3):", round(w, 1))
ms = []
for i in range(0, len(a48) - block, block):
    _, _, perf = vc.on_request(a48[i : i + block], f0_up_key=0, index_rate=0.3, protect=0.33)
    ms.append(perf[1])
ms = np.array(ms)
print(f"blocks={len(ms)} block_ms={block / 48:.0f} proc ms: mean={ms.mean():.0f} p50={np.median(ms):.0f} "
      f"p95={np.percentile(ms, 95):.0f} max={ms.max():.0f}")
print(f"est. chain latency (block + p95 proc) = {block / 48 + np.percentile(ms, 95):.0f} ms; "
      f"RTF(mean)={ms.mean() / (block / 48):.2f}")
print("ru_maxrss MB", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)
