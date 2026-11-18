"""Example plugin: change the volume of a 16-bit WAV file. Standard library only.

The app calls run(action, inputs, ctx). ctx.work_dir is the only place a plugin may write result files;
return their names (relative to work_dir) in "outputs".
"""
import array
import os
import sys
import wave


def run(action, inputs, ctx):
    src = inputs.get("audio")
    if not isinstance(src, str) or not os.path.isfile(src):
        raise ValueError("Choose an audio file first.")
    gain = float(inputs.get("gain_db", 6))
    factor = 10 ** (gain / 20.0)
    ctx.status("Reading the file")
    with wave.open(src, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError("Only 16-bit WAV files are supported.")
        params = w.getparams()
        raw = w.readframes(w.getnframes())
    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()
    ctx.status("Changing the volume")
    n = len(samples)
    for i in range(n):
        v = int(round(samples[i] * factor))
        samples[i] = -32768 if v < -32768 else 32767 if v > 32767 else v
        if i % 200000 == 0 and n:
            ctx.progress(i / n)
    if sys.byteorder == "big":
        samples.byteswap()
    name = "gain.wav"
    with wave.open(os.path.join(ctx.work_dir, name), "wb") as out:
        out.setparams(params)
        out.writeframes(samples.tobytes())
    ctx.progress(1.0)
    return {"outputs": [name], "text": "%+.1f dB" % gain}
