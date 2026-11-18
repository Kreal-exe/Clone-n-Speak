"""Plugins: manifest, install, per-plugin environment and sandbox (stdlib only, Python 3.9+).

A plugin is a folder with plugin.json and an entry file (main.py) that defines run(action, inputs, ctx).
It runs in its own process (cns_plugin_host.py) under sandbox-exec, with an allowlisted environment.
Nothing heavy is imported here: the worker loads this module at start-up.
"""
import hashlib
import uuid
import json
import os
import pwd
import re
import shutil
import tempfile

ID_RE = r"^[a-z0-9][a-z0-9_-]{1,39}$"
ACTION_RE = r"^[a-z0-9][a-z0-9_-]{0,39}$"
TOKEN_VAR = "CNS_PLUGIN_TOKEN"
MAX_BYTES = 50 * 1024 * 1024
MAX_FILES = 2000
MAX_STR = 200
DEFAULT_TIMEOUT = 600
MAX_TIMEOUT = 3600
INPUT_TYPES = ("audio", "text", "number", "choice")
PERMISSIONS = ("network",)
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
# Programs a plugin must not start: they reach outside the sandbox through LaunchServices, Apple Events, launchd, the
# keychain or the clipboard. (Exec of anything inside the plugin's own writable folders is denied too.)
DENY_EXEC = ("/usr/bin/open", "/usr/bin/osascript", "/bin/launchctl", "/usr/bin/automator", "/usr/bin/shortcuts",
             "/usr/sbin/screencapture", "/usr/bin/security", "/usr/bin/sudo", "/usr/bin/su", "/usr/bin/defaults",
             "/usr/bin/pbcopy", "/usr/bin/pbpaste", "/usr/bin/sandbox-exec", "/usr/bin/ssh", "/usr/bin/scp",
             "/usr/bin/nc", "/usr/bin/osacompile", "/usr/bin/say", "/usr/bin/afplay")
# Mach services behind `open`-style escapes (LaunchServices, Apple Events, pasteboard).
DENY_MACH = ("com.apple.coreservices.launchservicesd", "com.apple.coreservices.appleevents", "com.apple.lsd.mapdb",
             "com.apple.lsd.modifydb", "com.apple.lsd.open", "com.apple.pasteboard.1",
             "com.apple.coreservices.quarantine-resolver", "com.apple.ScreenCaptureAgent")


class PluginError(ValueError):
    pass


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _text(m, key, required=True):
    v = m.get(key)
    if v is None and not required:
        return ""
    if not isinstance(v, str) or (required and not v.strip()):
        raise PluginError("plugin.json: \"%s\" must be a non-empty string" % key)
    if len(v) > MAX_STR:
        raise PluginError("plugin.json: \"%s\" is longer than %d characters" % (key, MAX_STR))
    return v


def _number(v, what):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise PluginError("plugin.json: %s must be a number" % what)
    return v


def _input(a_id, raw):
    if not isinstance(raw, dict):
        raise PluginError("plugin.json: an input of action \"%s\" must be an object" % a_id)
    name = raw.get("name")
    if not isinstance(name, str) or not re.match(r"^[A-Za-z_][A-Za-z0-9_]{0,39}$", name):
        raise PluginError("plugin.json: bad input name in action \"%s\"" % a_id)
    typ = raw.get("type")
    if typ not in INPUT_TYPES:
        raise PluginError("plugin.json: input \"%s\" has an unknown type (use %s)" % (name, ", ".join(INPUT_TYPES)))
    out = {"name": name, "type": typ, "label": _text(raw, "label", False) or name}
    where = "input \"%s\"" % name
    if typ == "number":
        for k in ("min", "max", "default"):
            if k in raw:
                out[k] = _number(raw[k], "%s of %s" % (k, where))
        if "min" in out and "max" in out and out["min"] > out["max"]:
            raise PluginError("plugin.json: %s has min above max" % where)
    elif typ == "choice":
        ch = raw.get("choices")
        if (not isinstance(ch, list) or not ch or len(ch) > 100
                or not all(isinstance(c, str) and 0 < len(c) <= MAX_STR for c in ch)):
            raise PluginError("plugin.json: %s needs a non-empty list of text choices" % where)
        out["choices"] = ch
        if "default" in raw:
            if raw["default"] not in ch:
                raise PluginError("plugin.json: default of %s is not one of its choices" % where)
            out["default"] = raw["default"]
    elif "default" in raw:
        if not isinstance(raw["default"], str):
            raise PluginError("plugin.json: default of %s must be text" % where)
        out["default"] = raw["default"]
    return out


def load_manifest(folder):
    """Reads and validates <folder>/plugin.json; returns the normalized manifest or raises PluginError."""
    folder = os.path.realpath(folder)
    path = os.path.join(folder, "plugin.json")
    if not os.path.isfile(path) or os.path.islink(path):
        raise PluginError("plugin.json not found in the plugin folder")
    try:
        with open(path, "rb") as f:
            raw = f.read(1 << 20)
        m = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError) as e:
        raise PluginError("plugin.json is not valid JSON: %s" % e)
    if not isinstance(m, dict):
        raise PluginError("plugin.json must be a JSON object")
    if m.get("schema") != 1 or isinstance(m.get("schema"), bool):
        raise PluginError("plugin.json: \"schema\" must be 1")
    pid = m.get("id")
    if not isinstance(pid, str) or not re.match(ID_RE, pid):
        raise PluginError("plugin.json: \"id\" must be 2-40 characters: a-z, 0-9, _ and -, starting with a letter or digit")
    out = {"schema": 1, "id": pid}
    for k in ("name", "version", "author", "description"):
        out[k] = _text(m, k)
    entry = m.get("entry")
    if not isinstance(entry, str) or not entry.strip() or len(entry) > 400:
        raise PluginError("plugin.json: \"entry\" must be the path of the plugin's main file")
    if os.path.isabs(entry) or ".." in entry.replace("\\", "/").split("/"):
        raise PluginError("plugin.json: \"entry\" points outside the plugin folder")
    full = os.path.realpath(os.path.join(folder, entry))
    if not _inside(full, folder):
        raise PluginError("plugin.json: \"entry\" points outside the plugin folder")
    if not os.path.isfile(full):
        raise PluginError("plugin.json: entry file \"%s\" does not exist" % entry)
    out["entry"] = entry
    acts = m.get("actions")
    if not isinstance(acts, list) or not acts or len(acts) > 50:
        raise PluginError("plugin.json: \"actions\" must be a non-empty list")
    out["actions"], seen = [], set()
    for a in acts:
        if not isinstance(a, dict) or not isinstance(a.get("id"), str) or not re.match(ACTION_RE, a["id"]):
            raise PluginError("plugin.json: every action needs an \"id\" (a-z, 0-9, _ and -)")
        if a["id"] in seen:
            raise PluginError("plugin.json: duplicate action \"%s\"" % a["id"])
        seen.add(a["id"])
        ins = a.get("inputs", [])
        if not isinstance(ins, list) or len(ins) > 30:
            raise PluginError("plugin.json: \"inputs\" of action \"%s\" must be a list" % a["id"])
        out["actions"].append({"id": a["id"], "label": _text(a, "label", False) or a["id"],
                               "inputs": [_input(a["id"], i) for i in ins]})
    perms = m.get("permissions", [])
    if not isinstance(perms, list) or any(p not in PERMISSIONS for p in perms):
        raise PluginError("plugin.json: \"permissions\" may only contain: %s" % ", ".join(PERMISSIONS))
    out["permissions"] = sorted(set(perms))
    t = m.get("timeout_s", DEFAULT_TIMEOUT)
    if isinstance(t, bool) or not isinstance(t, int) or not 1 <= t <= MAX_TIMEOUT:
        raise PluginError("plugin.json: \"timeout_s\" must be a whole number of seconds from 1 to %d" % MAX_TIMEOUT)
    out["timeout_s"] = t
    return out


def validate_inputs(action, inputs):
    """Checks the inputs of a run against the action of the manifest (types, ranges, choices) and fills defaults.
    Anything the API or the Bridge sends goes through here before the plugin sees it."""
    if not isinstance(inputs, dict):
        raise PluginError("The inputs must be an object")
    declared = {i["name"]: i for i in action.get("inputs", [])}
    extra = sorted(set(inputs) - set(declared))
    if extra:
        raise PluginError("Unknown input: %s" % ", ".join(str(k)[:40] for k in extra))
    out = {}
    for name, spec in declared.items():
        typ = spec["type"]
        if name not in inputs or inputs[name] is None:
            if "default" in spec:
                out[name] = spec["default"]
            elif typ == "text":
                out[name] = ""
            else:
                raise PluginError("Input \"%s\" is required" % spec["label"])
            continue
        v = inputs[name]
        if typ == "number":
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
                raise PluginError("Input \"%s\" must be a number" % spec["label"])
            if ("min" in spec and v < spec["min"]) or ("max" in spec and v > spec["max"]):
                raise PluginError("Input \"%s\" is out of range" % spec["label"])
        elif typ == "choice":
            if v not in spec["choices"]:
                raise PluginError("Input \"%s\" is not one of the choices" % spec["label"])
        elif typ == "audio":
            if not isinstance(v, str) or not v.strip() or len(v) > 4096 or "\0" in v:
                raise PluginError("Input \"%s\" must be a file path" % spec["label"])
        else:
            if not isinstance(v, str) or len(v) > 100000:
                raise PluginError("Input \"%s\" must be text" % spec["label"])
        out[name] = v
    return out


def _walk(folder):
    """Relative paths of all entries (files and folders), sorted. Refuses symlinks, hard-linked files and folders
    with more than MAX_FILES entries or MAX_BYTES of files (a hand-copied folder must not stall the app)."""
    found, total = [], 0
    for root, dirs, files in os.walk(folder, followlinks=False):
        dirs.sort()
        for n in dirs + files:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, folder)
            st = os.lstat(p)
            if os.path.islink(p):
                raise PluginError("The plugin contains a symbolic link (%s); links are not allowed" % rel)
            if os.path.isfile(p) and st.st_nlink > 1:
                raise PluginError("The plugin contains a hard-linked file (%s); links are not allowed" % rel)
            total += st.st_size if os.path.isfile(p) else 0
            if len(found) >= MAX_FILES + MAX_FILES // 4 or total > MAX_BYTES:
                raise PluginError("The plugin folder is too big (more than %d files or %d MB)" % (MAX_FILES, MAX_BYTES >> 20))
            found.append((rel, p))
    return sorted(found)


def folder_digest(folder):
    """SHA-256 over relative paths and contents, deterministic. Finder droppings are ignored."""
    h = hashlib.sha256()
    for rel, p in _walk(folder):
        if os.path.basename(rel) == ".DS_Store":
            continue
        if os.path.isdir(p):
            h.update(b"D\0" + rel.encode("utf-8", "surrogateescape") + b"\0")
            continue
        h.update(b"F\0" + rel.encode("utf-8", "surrogateescape") + b"\0")
        with open(p, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()


def needs_trust(stored, current):
    """True when the user has to agree again: nothing stored, or the files changed since."""
    return not (isinstance(stored, str) and stored and stored == current)


def _check_tree(src):
    total, count = 0, 0
    for rel, p in _walk(src):
        if os.path.basename(rel) == ".DS_Store" or os.path.isdir(p):
            continue
        if not os.path.isfile(p):
            raise PluginError("The plugin contains a special file (%s)" % rel)
        count += 1
        total += os.path.getsize(p)
        if count > MAX_FILES:
            raise PluginError("The plugin has more than %d files" % MAX_FILES)
        if total > MAX_BYTES:
            raise PluginError("The plugin is larger than %d MB" % (MAX_BYTES >> 20))


def install(src_folder, plugins_dir):
    """Copies a plugin folder to <plugins_dir>/<id>/ atomically; returns the id."""
    src = os.path.realpath(src_folder)
    if not os.path.isdir(src):
        raise PluginError("Not a folder")
    manifest = load_manifest(src)
    _check_tree(src)
    pid = manifest["id"]
    os.makedirs(plugins_dir, exist_ok=True)
    dest = os.path.join(plugins_dir, pid)
    if os.path.lexists(dest):
        raise PluginError("A plugin with the id \"%s\" is already installed" % pid)
    tmp = tempfile.mkdtemp(prefix=".install-", dir=plugins_dir)
    try:
        staged = os.path.join(tmp, pid)
        os.mkdir(staged)
        for rel, p in _walk(src):
            if os.path.basename(rel) == ".DS_Store":
                continue
            target = os.path.join(staged, rel)
            if os.path.isdir(p):
                os.makedirs(target, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(p, target)
                shutil.copymode(p, target)
        load_manifest(staged)
        os.rename(staged, dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return pid


def build_env(parent, work_dir, data_dir, token=None):
    """The whole environment of a plugin process: an allowlist, never a copy of the user's environment."""
    lang = str((parent or {}).get("LANG") or "")
    if not re.match(r"^[A-Za-z0-9_.@-]{1,40}$", lang):
        lang = "en_US.UTF-8"
    off = str((parent or {}).get("OV_OFFLINE") or "")
    env = {"PATH": "/usr/bin:/bin", "HOME": data_dir, "TMPDIR": work_dir, "LANG": lang,
           "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
           "OV_OFFLINE": "1" if off.lower() in ("1", "true", "yes") else "0"}
    if token:   # per-run marker: the relay finds orphans that detached from the process tree by it
        env[TOKEN_VAR] = token
    return env


def _q(path):
    return '"%s"' % os.path.realpath(path).replace("\\", "\\\\").replace('"', '\\"')


def _qraw(path):
    return '"%s"' % path.replace("\\", "\\\\").replace('"', '\\"')


def _home():
    return os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)


def python_read_roots(python):
    """Folders a Python needs to start: its venv (if any) and the installation the venv points to."""
    roots = [os.path.dirname(os.path.dirname(os.path.abspath(python))),
             os.path.dirname(os.path.dirname(os.path.realpath(python)))]
    return [r for i, r in enumerate(roots) if r not in roots[:i]]


def symlinks_on(path):
    """Every symlink met while resolving `path` (the links themselves): reading one is needed to follow it."""
    found, todo, guard = [], [os.path.abspath(path)], 0
    while todo and guard < 50:
        guard += 1
        parts = todo.pop().split(os.sep)
        cur = os.sep
        for i, part in enumerate(parts[1:], 1):
            cur = os.path.join(cur, part)
            if os.path.islink(cur):
                if cur not in found:
                    found.append(cur)
                tgt = os.readlink(cur)
                tgt = tgt if os.path.isabs(tgt) else os.path.join(os.path.dirname(cur), tgt)
                todo.append(os.path.normpath(os.path.join(tgt, *parts[i + 1:])))
                break
    return found


def python_read_files(python):
    """The interpreter itself and the symlinks on the way to it."""
    return [os.path.abspath(python)] + symlinks_on(python)


def host_read_files(host):
    """The only files of the app's runtime folder the plugin host needs (it must not read the rest of it)."""
    d = os.path.dirname(os.path.abspath(host))
    # the folder itself is listed by the import system (names only); the other files in it stay unreadable
    return [d, os.path.abspath(host)] + [os.path.join(d, n) for n in ("cns_proto.py", "cns_plugins.py")]


def sandbox_profile(work_dir, data_dir, allow_network, plugin_dir=None, read_roots=(), read_files=()):
    """sandbox-exec profile for a plugin process. Last matching rule wins.
    - network: closed unless allowed;
    - writes: only work_dir and data_dir (+ /dev/null);
    - reads: everything outside the user's home and /Volumes (system libraries, Python), but inside them only
      work_dir, data_dir, plugin_dir, read_roots (Python) and read_files (host scripts, input files) and the exact files in read_files
      (the job's input files);
    - exec: nothing from DENY_EXEC and nothing written into the plugin's own folders; Mach services of LaunchServices
      and Apple Events are closed, so `open`-style escapes fail.
    Paths are resolved (/tmp -> /private/tmp). Task 7.1's cns_engines.sandbox_profile does not fit: it keeps every
    read open on purpose, and a plugin is untrusted code."""
    home = _home()
    folders = [work_dir, data_dir] + ([plugin_dir] if plugin_dir else []) + list(read_roots)
    lines = ["(version 1)", "(allow default)"]
    if not allow_network:
        lines.append("(deny network*)")
    lines.append("(deny file-write*)")
    lines.append("(allow file-write* (subpath %s) (subpath %s) (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))"
                 % (_q(work_dir), _q(data_dir)))
    lines.append("(deny file-read* (subpath %s) (subpath \"/Volumes\"))" % _q(home))
    allow = ["(subpath %s)" % _q(f) for f in folders] + ["(literal %s)" % (_qraw(f) if os.path.islink(f) else _q(f)) for f in read_files]
    lines.append("(allow file-read* %s)" % " ".join(allow))
    # the folders above sit under the home folder: let the path be resolved (names only, no contents)
    anc = set()
    for d in [os.path.dirname(os.path.realpath(f)) for f in folders] + [os.path.realpath(os.path.dirname(f)) for f in read_files]:
        while d.startswith(home) and d not in anc:
            anc.add(d)
            d = os.path.dirname(d)
    anc.add(home)
    lines.append("(allow file-read-metadata %s)" % " ".join("(literal %s)" % _q(d) for d in sorted(anc)))
    lines.append("(deny process-exec %s)" % " ".join("(literal \"%s\")" % e for e in DENY_EXEC))
    lines.append("(deny process-exec (subpath %s) (subpath %s))" % (_q(work_dir), _q(data_dir)))
    lines.append("(deny mach-lookup %s)" % " ".join("(global-name \"%s\")" % m for m in DENY_MACH))
    lines.append("(deny appleevent-send)")
    lines.append("(deny signal)")                           # cannot kill the relay, the app or anything else ...
    lines.append("(allow signal (target self) (target children))")   # ... only itself and its own children
    lines.append("(deny process-info* (target others))")
    lines.append("(deny mach-priv-task-port)")
    return "\n".join(lines) + "\n"


def command(python, host, plugin_dir, action, profile_path):
    return [SANDBOX_EXEC, "-f", profile_path, python, host, "--plugin", plugin_dir, "--action", action]


def sandbox_available():
    return os.access(SANDBOX_EXEC, os.X_OK)


# --- command line for the app (the app has no other way to call this module) --------------------------------------
# python cns_plugins.py list <plugins_dir>
# python cns_plugins.py install <src_folder> <plugins_dir>
# python cns_plugins.py digest <folder>
# python cns_plugins.py launch <python> <host> <plugin_dir> <action> <work_dir> <data_dir> <allow_network 0|1> <profile> [input files...]
# Prints one JSON value on stdout; {"error": "..."} on a refused request.

def list_plugins(plugins_dir):
    out = []
    try:
        names = sorted(os.listdir(plugins_dir))
    except OSError:
        return out
    for n in names:
        folder = os.path.join(plugins_dir, n)
        if n.startswith(".") or not os.path.isdir(folder):
            continue
        item = {"folder": folder, "dir_id": n}
        try:
            m = load_manifest(folder)
            if m["id"] != n:
                raise PluginError("The folder name does not match the plugin id")
            item["manifest"], item["digest"] = m, folder_digest(folder)
        except (PluginError, OSError) as e:
            item["error"] = str(e)
        out.append(item)
    return out


def launch(python, host, plugin_dir, action, work_dir, data_dir, allow_network, profile_path, read_files=()):
    """Writes the sandbox profile; returns the argv and the environment to start the plugin with. The argv runs the
    relay (outside the sandbox: filters the events, enforces the timeout, kills the whole process tree) which in turn
    runs sandbox-exec + the host."""
    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(data_dir, exist_ok=True)
    timeout = load_manifest(plugin_dir)["timeout_s"]
    host_dir = os.path.dirname(os.path.abspath(host))
    files = [f for f in read_files if isinstance(f, str) and os.path.isabs(f)]
    files += host_read_files(host)
    with open(profile_path, "w") as f:
        f.write(sandbox_profile(work_dir, data_dir, allow_network, plugin_dir,
                                python_read_roots(python), files + python_read_files(python)))
    relay = os.path.join(host_dir, "cns_plugin_relay.py")
    return {"argv": [python, relay, "--work", work_dir, "--timeout", str(timeout), "--"]
            + command(python, host, plugin_dir, action, profile_path),
            "env": build_env(os.environ, work_dir, data_dir, uuid.uuid4().hex)}


def _cli(argv):
    import sys
    try:
        cmd = argv[0]
        if cmd == "list":
            res = list_plugins(argv[1])
        elif cmd == "install":
            res = {"id": install(argv[1], argv[2])}
        elif cmd == "digest":
            res = {"digest": folder_digest(argv[1])}
        elif cmd == "launch":
            res = launch(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7] == "1", argv[8], argv[9:])
        else:
            res = {"error": "unknown command"}
    except (PluginError, OSError, IndexError) as e:
        res = {"error": str(e)}
    sys.stdout.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    import sys
    _cli(sys.argv[1:])
