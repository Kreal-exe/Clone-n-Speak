"""The trusted parent of a plugin process (stdlib only; runs OUTSIDE the sandbox, started by the app).

    python cns_plugin_relay.py --work DIR --timeout SECONDS -- <sandbox-exec ... host ...>

It does what the sandboxed plugin must not be trusted with:
  * the plugin's stdout is a pipe to this process, so the plugin cannot write to the app's event channel directly:
    every event is re-emitted here, and result outputs / partial paths are kept only if their real path is inside --work;
  * the timeout is enforced here (SIGKILL), not only inside the plugin's own process;
  * on timeout, on SIGTERM from the app (Stop) and when the plugin ends, the whole process tree is killed, including
    children that detached with setsid (the tree is sampled twice a second, so they are found while still attached).
    Remaining limit: a process that double-forks, calls setsid and is re-parented to launchd between two samples
    (under 0.5 s) escapes the tree; the sandbox (no network, no writes outside the plugin's folders, no exec of
    `open`/`osascript`) is what bounds the damage then. The app's SIGKILL of the process group still reaches every
    process that stayed in the group.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_proto as proto  # noqa: E402

KINDS = ("status", "progress", "log", "partial", "result", "error")
POLL = 0.5


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def process_table():
    """{pid: ppid} of every process."""
    try:
        out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = int(parts[1])
    return table


def descendants(root, table=None):
    table = process_table() if table is None else table
    kids = {}
    for pid, ppid in table.items():
        kids.setdefault(ppid, []).append(pid)
    found, todo = set(), [root]
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in found:
                found.add(c)
                todo.append(c)
    return found


class Tree:
    """The child and every descendant seen so far."""

    def __init__(self, root):
        self.root = root
        self.seen = {root}
        self.me = os.getpid()
        self.lock = threading.Lock()

    def sample(self):
        found = descendants(self.root)
        with self.lock:
            self.seen |= found
            self.seen.discard(self.me)

    def _alive(self):
        """Seen pids that still exist and still belong to the tree (a child of the tree, or re-parented to launchd);
        a reused pid of an unrelated process does not match."""
        table = process_table()
        with self.lock:
            seen = set(self.seen)
        return {p for p in seen if p in table and (p == self.root or table[p] in seen or table[p] == 1)}

    def kill(self, grace=0.0):
        self.sample()
        if grace:
            self._signal(self._alive(), signal.SIGTERM)
            time.sleep(grace)
            self.sample()
        self._signal(self._alive(), signal.SIGKILL)

    def _signal(self, pids, sig):
        for pid in pids:
            if pid and pid != self.me:
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass


def sanitize(ev, work):
    """Returns the event to forward, or (None, reason). Outputs and partial files must live inside `work`."""
    kind = ev.get("event")
    if kind not in KINDS:
        return None, "unknown event"
    root = os.path.realpath(work)
    if kind == "result":
        data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
        keep, dropped = [], []
        for o in data.get("outputs") or []:
            real = os.path.realpath(o) if isinstance(o, str) and os.path.isabs(o) else None
            if real and _inside(real, root) and os.path.isfile(real):
                keep.append(real)
            else:
                dropped.append(str(o)[:200])
        res = {"outputs": keep}
        if data.get("text") is not None:
            res["text"] = str(data["text"])[:20000]
        return {"event": "result", "data": res, "_dropped": dropped}, None
    if kind == "partial":
        real = os.path.realpath(ev["path"]) if isinstance(ev.get("path"), str) else None
        if not (real and _inside(real, root)):
            return None, "partial path outside the work folder"
    return ev, None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    proto.install_stdout_guard()
    if not cmd:
        proto.fail("No plugin command")
        return 1
    request = sys.stdin.buffer.read()
    try:
        child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None, cwd=args.work)
    except OSError as e:
        proto.fail("The plugin could not be started: %s" % e)
        return 1
    tree = Tree(child.pid)

    def on_term(signum, frame):
        tree.kill(grace=1.0)
        os._exit(143)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)

    state = {"errored": False, "resulted": False}

    def pump():
        for raw in child.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                ev = None
            if not isinstance(ev, dict):
                sys.stderr.write(raw.decode("utf-8", "replace"))
                continue
            out, why = sanitize(ev, args.work)
            if out is None:
                proto.log("Dropped a plugin event (%s)" % why)
                continue
            dropped = out.pop("_dropped", [])
            for d in dropped:
                proto.log("Dropped an output outside the work folder: %s" % d)
            if out["event"] == "error":
                state["errored"] = True
            if out["event"] == "result":
                state["resulted"] = True
            proto.emit(out.pop("event"), **out)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        child.stdin.write(request)
        child.stdin.close()
    except OSError:
        pass
    deadline = time.monotonic() + max(1, args.timeout)
    timed_out = False
    last = 0.0
    while child.poll() is None:
        now = time.monotonic()
        if now >= deadline:
            timed_out = True
            break
        if now - last >= POLL:
            tree.sample()
            last = now
        time.sleep(0.05)
    if timed_out:
        tree.kill()
        child.wait()
        reader.join(2)
        proto.fail("The plugin ran longer than %d seconds and was stopped" % args.timeout)
        return 1
    tree.kill()                      # stragglers that outlived the plugin; also frees the pipe for the reader
    reader.join(5)
    if child.returncode != 0 and not state["errored"] and not state["resulted"]:
        proto.fail("The plugin ended with exit code %d" % child.returncode)
    return 0 if child.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
