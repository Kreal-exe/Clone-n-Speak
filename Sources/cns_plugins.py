"""Plugins: manifest, install, per-plugin environment and sandbox (stdlib only, Python 3.9+).

A plugin is a folder with plugin.json and an entry file (main.py) that defines run(action, inputs, ctx).
It runs in its own process (cns_plugin_host.py) under sandbox-exec, with an allowlisted environment.
Nothing heavy is imported here: the worker loads this module at start-up.
"""
import hashlib
import json
import os
import re
import shutil
import tempfile

ID_RE = r"^[a-z0-9][a-z0-9_-]{1,39}$"
ACTION_RE = r"^[a-z0-9][a-z0-9_-]{0,39}$"
MAX_BYTES = 50 * 1024 * 1024
MAX_FILES = 2000
MAX_STR = 200
DEFAULT_TIMEOUT = 600
MAX_TIMEOUT = 3600
INPUT_TYPES = ("audio", "text", "number", "choice")
PERMISSIONS = ("network",)
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
# Places inside the user's home a plugin must not even read (the sandbox denies reads there).
SECRET_DIRS = (".ssh", ".aws", ".gnupg", ".config", ".kube", ".docker", "Library/Keychains", "Library/Cookies",
               "Library/Mail", "Library/Messages", "Library/Safari")


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


def _walk(folder):
    """Relative paths of all entries (files and folders), sorted; raises on symlinks."""
    found = []
    for root, dirs, files in os.walk(folder, followlinks=False):
        dirs.sort()
        for n in dirs + files:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, folder)
            if os.path.islink(p):
                raise PluginError("The plugin contains a symbolic link (%s); links are not allowed" % rel)
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


def build_env(parent, work_dir, data_dir):
    """The whole environment of a plugin process: an allowlist, never a copy of the user's environment."""
    lang = str((parent or {}).get("LANG") or "")
    if not re.match(r"^[A-Za-z0-9_.@-]{1,40}$", lang):
        lang = "en_US.UTF-8"
    off = str((parent or {}).get("OV_OFFLINE") or "")
    return {"PATH": "/usr/bin:/bin", "HOME": data_dir, "TMPDIR": work_dir, "LANG": lang,
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "OV_OFFLINE": "1" if off.lower() in ("1", "true", "yes") else "0"}


def _q(path):
    return '"%s"' % os.path.realpath(path).replace("\\", "\\\\").replace('"', '\\"')


def sandbox_profile(work_dir, data_dir, allow_network):
    """sandbox-exec profile: everything allowed except network (unless allowed), writing outside the
    plugin's own folders, and reading the user's secret folders. Paths are resolved (/tmp -> /private/tmp).
    NOTE: Task 7.1's cns_engines.sandbox_profile does the same job for pro engines; dedupe later."""
    home = os.path.realpath(os.path.expanduser("~"))
    lines = ["(version 1)", "(allow default)"]
    if not allow_network:
        lines.append("(deny network*)")
    lines.append("(deny file-write*)")
    lines.append("(allow file-write* (subpath %s) (subpath %s) (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))"
                 % (_q(work_dir), _q(data_dir)))
    lines.append("(deny file-read* %s)" % " ".join("(subpath %s)" % _q(os.path.join(home, d)) for d in SECRET_DIRS))
    return "\n".join(lines) + "\n"


def command(python, host, plugin_dir, action, profile_path):
    return [SANDBOX_EXEC, "-f", profile_path, python, host, "--plugin", plugin_dir, "--action", action]


def sandbox_available():
    return os.access(SANDBOX_EXEC, os.X_OK)


# --- command line for the app (the app has no other way to call this module) --------------------------------------
# python cns_plugins.py list <plugins_dir>
# python cns_plugins.py install <src_folder> <plugins_dir>
# python cns_plugins.py digest <folder>
# python cns_plugins.py launch <python> <host> <plugin_dir> <action> <work_dir> <data_dir> <allow_network 0|1> <profile>
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


def launch(python, host, plugin_dir, action, work_dir, data_dir, allow_network, profile_path):
    """Writes the sandbox profile; returns the argv and the environment to start the plugin host with."""
    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(data_dir, exist_ok=True)
    with open(profile_path, "w") as f:
        f.write(sandbox_profile(work_dir, data_dir, allow_network))
    return {"argv": command(python, host, plugin_dir, action, profile_path),
            "env": build_env(os.environ, work_dir, data_dir)}


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
            res = launch(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7] == "1", argv[8])
        else:
            res = {"error": "unknown command"}
    except (PluginError, OSError, IndexError) as e:
        res = {"error": str(e)}
    sys.stdout.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    import sys
    _cli(sys.argv[1:])
