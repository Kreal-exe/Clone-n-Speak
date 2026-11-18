"""Stand-in for the app: streams a wav to a running cns_realtime.py over its Unix socket and prints round-trip stats.

usage: python rt_client_check.py SOCKET_PATH INPUT.wav [BLOCK_S=0.15] [SECONDS=20]
Sends blocks at real-time pace (one per block duration), measures send -> reply time, prints p50/p95/max and the drops.
Start the engine first (see Sources/cns_realtime.py); the target is p95 round trip <= 120 ms on a quiet Mac.
"""
import os
import select
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources"))
import cns_rt_proto as rt  # noqa: E402


def main(argv):
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    sock_path, wav = argv[0], argv[1]
    block_s = float(argv[2]) if len(argv) > 2 else 0.15
    seconds = float(argv[3]) if len(argv) > 3 else 20.0
    a, sr = sf.read(wav)
    if a.ndim > 1:
        a = a.mean(1)
    a = resample_poly(a, 48000, sr).astype(np.float32)
    a = np.tile(a, int(seconds * 48000 // max(1, len(a))) + 1)
    n = rt.block_frame(block_s)
    c = rt.connect_unix(sock_path)
    dec = rt.FrameDecoder()
    sent, rtt, dropped = {}, [], 0
    start = time.perf_counter()
    for seq, i in enumerate(range(0, len(a) - n, n)):
        due = start + seq * n / 48000.0
        while time.perf_counter() < due:
            time.sleep(0.001)
        sent[seq] = time.perf_counter()
        c.sendall(rt.pack_audio(seq, a[i:i + n]))
        while select.select([c], [], [], 0)[0]:     # blocking sends; poll replies without a socket timeout
            for ftype, rseq, rn, _ in rt.read_frames(c, dec):
                if rn == 0:
                    dropped += 1
                    sent.pop(rseq, None)
                elif rseq in sent:
                    rtt.append((time.perf_counter() - sent.pop(rseq)) * 1000)
    end = time.perf_counter() + 2.0
    try:
        while sent and time.perf_counter() < end:
            if select.select([c], [], [], 0.1)[0]:
                for ftype, rseq, rn, _ in rt.read_frames(c, dec):
                    if rn and rseq in sent:
                        rtt.append((time.perf_counter() - sent.pop(rseq)) * 1000)
                    else:
                        sent.pop(rseq, None)
    except rt.PeerClosed:
        pass
    r = np.array(rtt) if rtt else np.zeros(1)
    print("blocks=%d dropped=%d round trip ms: p50=%.0f p95=%.0f max=%.0f (target p95 <= 120)"
          % (len(rtt), dropped, np.percentile(r, 50), np.percentile(r, 95), r.max()))
    c.close()


if __name__ == "__main__":
    main(sys.argv[1:])
