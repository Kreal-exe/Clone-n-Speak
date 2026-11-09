"""Time Applio RVC inference in-process: first call (cold) and repeats (warm).

usage: python -I infer_bench.py APPLIO_DIR DEVICE(mps|cpu) INPUT_WAV OUT_DIR PTH INDEX [REPEATS] [F0_METHOD]
"""
import os
import sys
import time

applio, device, inp, out_dir, pth, index = sys.argv[1:7]
repeats = int(sys.argv[7]) if len(sys.argv) > 7 else 3
f0 = sys.argv[8] if len(sys.argv) > 8 else "rmvpe"
os.chdir(applio)
sys.path.insert(0, applio)
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import resource  # noqa: E402

import torch  # noqa: E402

if device == "cpu":
    torch.backends.mps.is_available = lambda: False  # force CPU
from rvc.infer.infer import VoiceConverter  # noqa: E402

t0 = time.time()
vc = VoiceConverter()
print("init s", round(time.time() - t0, 2), "device", vc.config.device)
for i in range(repeats):
    t = time.time()
    vc.convert_audio(
        audio_input_path=inp,
        audio_output_path=os.path.join(out_dir, f"bench_{device}_{i}.wav"),
        model_path=pth,
        index_path=index,
        pitch=0,
        index_rate=0.3,
        volume_envelope=1.0,
        protect=0.33,
        f0_method=f0,
        f0_autotune=False,
        f0_autotune_strength=1.0,
        proposed_pitch=False,
        proposed_pitch_threshold=155.0,
        export_format="WAV",
        embedder_model="contentvec",
        embedder_model_custom=None,
        formant_shifting=False,
        formant_qfrency=1.0,
        formant_timbre=1.0,
        sid=0,
        inference_engine=None,
        onnx_precision="auto",
        cleanup_mode="off",
        cleanup_strength=12,
    )
    print(f"run {i} {device}: {time.time() - t:.2f} s", flush=True)
print("ru_maxrss MB", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)
