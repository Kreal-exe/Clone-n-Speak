"""Runs ONE plugin action in its own process (stdlib only; started by the app inside the plugin's
environment and sandbox). stdin: one JSON line {"inputs": {...}, "work_dir": "..."}; stdout: protocol events
(status/progress/log/result/error); everything a plugin prints goes to stderr."""
import argparse
import importlib.util
import json
import os
import signal
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_proto as proto  # noqa: E402


class Ctx:
    def __init__(self, work_dir, data_dir):
        self.work_dir = work_dir
        self.data_dir = data_dir

    def status(self, msg):
        proto.status(msg)

    def progress(self, value):
        proto.progress(value)

    def log(self, line):
        proto.log(line)


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def check_outputs(outputs, work_dir):
    """Relative names inside work_dir only; returns absolute real paths of existing regular files."""
    if not isinstance(outputs, (list, tuple)):
        raise ValueError("\"outputs\" must be a list of file names")
    root = os.path.realpath(work_dir)
    out = []
    for o in outputs:
        if not isinstance(o, str) or not o.strip():
            raise ValueError("an output name must be text")
        if os.path.isabs(o) or ".." in o.replace("\\", "/").split("/"):
            raise ValueError("output \"%s\" is outside the work folder" % o)
        real = os.path.realpath(os.path.join(root, o))
        if not _inside(real, root):
            raise ValueError("output \"%s\" is outside the work folder" % o)
        if not os.path.isfile(real):
            raise ValueError("output \"%s\" was not created" % o)
        out.append(real)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugin", required=True)
    ap.add_argument("--action", required=True)
    args = ap.parse_args(argv)
    proto.install_stdout_guard()
    try:
        req = proto.read_request()
        folder = os.path.realpath(args.plugin)
        with open(os.path.join(folder, "plugin.json"), "r", encoding="utf-8") as f:
            manifest = json.load(f)
        action = next((a for a in manifest.get("actions", []) if a.get("id") == args.action), None)
        if action is None:
            raise ValueError("The plugin has no action \"%s\"" % args.action)
        entry = os.path.realpath(os.path.join(folder, manifest["entry"]))
        if not _inside(entry, folder) or not os.path.isfile(entry):
            raise ValueError("The plugin's entry file is outside its folder")
        work_dir = str(req.get("work_dir") or os.environ.get("TMPDIR") or "")
        if not work_dir or not os.path.isdir(work_dir):
            raise ValueError("No work folder")
        inputs = req.get("inputs") or {}
        if not isinstance(inputs, dict):
            raise ValueError("\"inputs\" must be an object")
        timeout = manifest.get("timeout_s", 600)
        if isinstance(timeout, int) and not isinstance(timeout, bool) and timeout > 0:
            def on_alarm(signum, frame):
                proto.fail("The plugin ran longer than %d seconds and was stopped" % timeout)
                os._exit(1)
            signal.signal(signal.SIGALRM, on_alarm)
            signal.alarm(min(timeout, 3600))
        sys.path.insert(0, folder)
        spec = importlib.util.spec_from_file_location("cns_plugin_main", entry)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        res = mod.run(args.action, inputs, Ctx(work_dir, os.environ.get("HOME", "")))
        if res is None:
            res = {}
        if not isinstance(res, dict):
            raise ValueError("run() must return a dict")
        data = {"outputs": check_outputs(res.get("outputs", []), work_dir)}
        if res.get("text") is not None:
            data["text"] = str(res["text"])[:20000]
        proto.result(**data)
        return 0
    except proto.ProtoError as e:
        proto.fail(str(e))
    except BaseException as e:  # a plugin may raise anything, even SystemExit
        if isinstance(e, KeyboardInterrupt):
            raise
        proto.fail("%s: %s" % (type(e).__name__, e) if str(e) else type(e).__name__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
