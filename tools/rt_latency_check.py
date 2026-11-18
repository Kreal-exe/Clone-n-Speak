#!/usr/bin/env python3
"""Independent check of the Realtime page's latency number (Task 7.9, step 3c).

Setup: start Realtime in Clone'n'Speak with Output = BlackHole (or any loopback device). Run this script, then clap
next to the microphone a few times (a sharp clap every second or so, 10 s). The script records two devices at once:
the microphone (what you said) and the loopback (what Realtime produced), finds the clap peaks in both and prints the
delay between them. It needs numpy and sounddevice (the pro engine's Python has both):

    ~/Library/Application\\ Support/Clone\\'n\\'Speak/engines/pro/.venv/bin/python tools/rt_latency_check.py \\
        --mic "MacBook Pro Microphone" --loop "BlackHole 2ch" --panel-ms 240

The loopback sees the converted sound BEFORE the output hardware latency, so the script adds --output-hw-ms (the page
shows the hardware part in its detail line) when comparing with the panel; the microphone side is compared the same way
via --input-hw-ms. A clap is not voiced, so use a short "pa" instead if the model returns silence for noise.
Result: PASS when |measured - panel| <= 30 ms. Nothing is saved to disk: the audio stays in memory.
"""
import argparse
import sys


def peaks(x, rate, min_gap_s=0.4, floor=0.08):
    """Times (s) of loud onsets: first sample above `floor` x max after a quiet gap."""
    import numpy as np
    a = np.abs(x)
    top = float(a.max()) if len(a) else 0.0
    if top < 1e-4:
        return []
    thr = max(floor * top, 0.02 * top)
    out, last = [], -1e9
    for i in np.flatnonzero(a > max(thr, 0.5 * top * 0.2)):
        t = i / rate
        if t - last >= min_gap_s:
            out.append(t)
        last = t
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mic", help="input device name or index (default: system input)")
    ap.add_argument("--loop", required=True, help="loopback input device name or index (BlackHole)")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--panel-ms", type=float, help="the number the Realtime page shows (p95 + hardware)")
    ap.add_argument("--input-hw-ms", type=float, default=0.0)
    ap.add_argument("--output-hw-ms", type=float, default=0.0)
    ap.add_argument("--rate", type=int, default=48000)
    a = ap.parse_args(argv)
    import numpy as np
    import sounddevice as sd

    def dev(v):
        if v is None:
            return None
        return int(v) if str(v).isdigit() else v

    n = int(a.seconds * a.rate)
    mic = sd.InputStream(device=dev(a.mic), channels=1, samplerate=a.rate, dtype="float32")
    loop = sd.InputStream(device=dev(a.loop), channels=1, samplerate=a.rate, dtype="float32")
    mic_buf, loop_buf = [], []
    print("Recording %.0f s: clap (or say \"pa\") every second..." % a.seconds)
    with mic, loop:
        got = 0
        while got < n:
            k = min(4800, n - got)
            m, _ = mic.read(k)
            l, _ = loop.read(k)
            mic_buf.append(m[:, 0].copy())
            loop_buf.append(l[:, 0].copy())
            got += k
    mic_x, loop_x = np.concatenate(mic_buf), np.concatenate(loop_buf)
    pm, pl = peaks(mic_x, a.rate), peaks(loop_x, a.rate)
    print("mic onsets:", ["%.2f" % t for t in pm])
    print("loop onsets:", ["%.2f" % t for t in pl])
    deltas = []
    for t in pm:
        later = [u for u in pl if 0.0 < u - t < 1.0]
        if later:
            deltas.append(later[0] - t)
    if len(deltas) < 3:
        print("Not enough matching claps (%d). Clap louder, check the devices, and run again." % len(deltas))
        return 2
    d = sorted(deltas)[len(deltas) // 2] * 1000.0
    total = d + a.input_hw_ms + a.output_hw_ms
    print("median mic -> loopback: %.0f ms (+ hardware %.0f ms) = %.0f ms" % (d, a.input_hw_ms + a.output_hw_ms, total))
    if a.panel_ms is None:
        return 0
    diff = abs(total - a.panel_ms)
    print("panel says %.0f ms, difference %.0f ms: %s" % (a.panel_ms, diff, "PASS" if diff <= 30 else "FAIL"))
    if total >= 300:
        print("Over 300 ms: not acceptable. Try block 0.10, fcpe, a 128-frame device buffer.")
    return 0 if diff <= 30 and total < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
