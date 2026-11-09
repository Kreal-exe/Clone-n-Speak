"""Sample the memory (top's MEM column, close to Activity Monitor's) of python processes whose command contains a string.

usage: python -I memwatch.py MATCH SECONDS_INTERVAL OUT_FILE   (stop it with SIGTERM; it prints the peak on exit)
Needed because /usr/bin/time -l only reports the first process, while Applio trains in a spawned child and the GPU
(MPS) memory lives in the process footprint, not in RSS.
"""
import re
import signal
import subprocess
import sys
import time

match, interval, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
peak = 0.0
stop = False


def on_term(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)
with open(out, "w") as f:
    while not stop:
        txt = subprocess.run(["top", "-l", "1", "-o", "mem", "-n", "6", "-stats", "pid,mem,command"],
                             capture_output=True, text=True).stdout
        cur = 0.0
        for line in txt.splitlines():
            m = re.match(r"\s*(\d+)\s+(\d+)([MGK])\S*\s+(.*)", line)
            if m and match in subprocess.run(["ps", "-o", "command=", "-p", m.group(1)], capture_output=True,
                                              text=True).stdout:
                v = float(m.group(2)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(3)]
                cur = max(cur, v)
        peak = max(peak, cur)
        f.write(f"{time.time():.0f} {cur:.0f} MB peak {peak:.0f}\n")
        f.flush()
        time.sleep(interval)
    f.write(f"PEAK {peak:.0f} MB\n")
print("peak MB", peak)
