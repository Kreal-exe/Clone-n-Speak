"""The trusted parent of a plugin process (stdlib only; runs OUTSIDE the sandbox, started by the app).

    python cns_plugin_relay.py --work DIR --timeout SECONDS -- <sandbox-exec ... host ...>

It does what the sandboxed plugin must not be trusted with:
  * the plugin's stdout is a pipe to this process, so the plugin cannot write to the app's event channel directly:
    every event is re-emitted here, and result outputs / partial paths are kept only if their real path is inside --work;
  * the timeout is enforced here (SIGKILL), not only inside the plugin's own process;
  * on timeout, on SIGTERM from the app (Stop) and when the plugin ends, the whole process tree is killed, including
    children that detached with setsid (the tree is sampled twice a second, so they are found while still attached).
    Orphans that were re-parented to launchd are found by the run's token (CNS_PLUGIN_TOKEN in their inherited
    environment, read from `ps -axeww`) and killed too. This is best effort: `ps` does not show the environment of
    every binary (it hides it for the app's own Python build, for instance), and a plugin can scrub its environment.
    Remaining limit: a process that detaches (double fork + setsid) between two samples (under 0.5 s) and is not
    visible by its token escapes and can outlive Stop; the sandbox (no network, no writes outside the plugin's folders, no exec of
    `open`/`osascript`) is what bounds the damage then. The app's SIGKILL of the process group still reaches every
    process that stayed in the group, and the sandbox forbids plugins to signal other processes.
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
MAX_LINE = 1 << 20       # one event line
MAX_PATHS = 256          # outputs of a result, partial events of a run
MAX_TEXT = 4000          # status / log / error messages
TOKEN_VAR = "CNS_PLUGIN_TOKEN"


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def token_pids(token, skip=()):
    """Pids of the user's processes whose environment carries the run's token (ps shows it for own processes)."""
    if not token:
        return set()
    try:
        p = subprocess.Popen(["/bin/ps", "-axeww", "-o", "pid=,command="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             errors="replace")
        skip = set(skip) | {p.pid, os.getpid()}
        out = p.communicate(timeout=15)[0]
    except (OSError, subprocess.SubprocessError):
        return set()
    needle = "%s=%s" % (TOKEN_VAR, token)
    found = set()
    for line in out.splitlines():
        head, _, rest = line.strip().partition(" ")
        if head.isdigit() and int(head) not in skip and needle in rest:
            found.add(int(head))
    return found


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

    def __init__(self, root, token=None):
        self.root = root
        self.token = token
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
        found = {p for p in seen if p in table and (p == self.root or table[p] in seen or table[p] == 1)}
        return found | token_pids(self.token)   # orphans that detached from the tree keep the run's token

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
        outs = data.get("outputs") if isinstance(data.get("outputs"), list) else []
        if len(outs) > MAX_PATHS:
            dropped.append("%d more outputs" % (len(outs) - MAX_PATHS))
        for o in outs[:MAX_PATHS]:
            real = os.path.realpath(o) if isinstance(o, str) and os.path.isabs(o) and "\0" not in o else None
            if real and _inside(real, root) and os.path.isfile(real):
                keep.append(real)
            else:
                dropped.append(str(o)[:200])
        res = {"outputs": keep}
        if data.get("text") is not None:
            res["text"] = str(data["text"])[:20000]
        return {"event": "result", "data": res, "_dropped": dropped}, None
    if kind == "partial":
        p = ev.get("path")
        real = os.path.realpath(p) if isinstance(p, str) and "\0" not in p else None
        if not (real and _inside(real, root)):
            return None, "partial path outside the work folder"
        return {"event": "partial", "path": real}, None
    if kind == "progress":
        v = ev.get("value")
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v <= 1:
            return None, "progress must be a number from 0 to 1"
        return {"event": "progress", "value": float(v)}, None
    if kind in ("status", "log", "error"):
        key = {"status": "msg", "log": "line", "error": "msg"}[kind]
        v = ev.get(key)
        if not isinstance(v, str):
            return None, "%s needs text" % kind
        return {"event": kind, key: v[:MAX_TEXT]}, None
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
    tree = Tree(child.pid, os.environ.get(TOKEN_VAR))

    def on_term(signum, frame):
        tree.kill(grace=1.0)
        os._exit(143)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)

    state = {"errored": False, "resulted": False}

    partials = [0]

    def handle(raw):
        if len(raw) > MAX_LINE:
            proto.log("Dropped a plugin line longer than %d bytes" % MAX_LINE)
            return
        try:
            ev = json.loads(raw)
        except (ValueError, RecursionError):
            ev = None
        if not isinstance(ev, dict):
            sys.stderr.write(raw.decode("utf-8", "replace")[:MAX_LINE])
            return
        out, why = sanitize(ev, args.work)
        if out is None:
            proto.log("Dropped a plugin event (%s)" % why)
            return
        if out["event"] == "partial":
            partials[0] += 1
            if partials[0] > MAX_PATHS:
                return
        for d in out.pop("_dropped", []):
            proto.log("Dropped an output outside the work folder: %s" % d[:200])
        if out["event"] == "error":
            state["errored"] = True
        if out["event"] == "result":
            state["resulted"] = True
        proto.emit(out.pop("event"), **out)

    def pump():
        while True:
            try:
                raw = child.stdout.readline(MAX_LINE + 1)
            except (OSError, ValueError):
                return
            if not raw:
                return
            if len(raw) > MAX_LINE and not raw.endswith(b"\n"):
                while True:                      # swallow the rest of the oversized line
                    rest = child.stdout.readline(MAX_LINE)
                    if not rest or rest.endswith(b"\n"):
                        break
            try:
                handle(raw)
            except Exception as e:               # nothing a plugin sends may stop the pump (it frees the pipe)
                try:
                    proto.log("Dropped a plugin event (%s)" % type(e).__name__)
                except Exception:
                    pass

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
