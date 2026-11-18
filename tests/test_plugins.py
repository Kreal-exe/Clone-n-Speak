import json
import os
import shutil
import socket
import subprocess
import sys
import signal
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Sources"))
import cns_plugins as P  # noqa: E402

FIX = os.path.join(ROOT, "tests", "fixtures", "plugins")
HOST = os.path.join(ROOT, "Sources", "cns_plugin_host.py")


def _sandbox_works():
    if not P.sandbox_available():
        return False
    with tempfile.TemporaryDirectory() as d:
        prof = os.path.join(d, "p.sb")
        with open(prof, "w") as f:
            f.write(P.sandbox_profile(d, d, False, None, P.python_read_roots(sys.executable) + [os.path.dirname(HOST)], P.python_read_files(sys.executable)))
        try:
            return subprocess.run(P.command(sys.executable, HOST, d, "x", prof)[:4] + ["-c", "pass"],
                                  capture_output=True, timeout=30).returncode == 0
        except Exception:
            return False


SANDBOX = _sandbox_works()


def copy_fixture(name, dest_root):
    dest = os.path.join(dest_root, name)
    shutil.copytree(os.path.join(FIX, name), dest, symlinks=True)
    return dest


def write_manifest(folder, **over):
    m = {"schema": 1, "id": "demo", "name": "Demo", "version": "1", "author": "A", "description": "D",
         "entry": "main.py", "actions": [{"id": "go"}]}
    m.update(over)
    for k in [k for k, v in m.items() if v is None]:
        del m[k]
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "plugin.json"), "w") as f:
        json.dump(m, f)
    if not os.path.exists(os.path.join(folder, "main.py")):
        with open(os.path.join(folder, "main.py"), "w") as f:
            f.write("def run(a, i, c): return {}\n")
    return folder


class Manifest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_manifest_valid_minimal(self):
        m = P.load_manifest(write_manifest(os.path.join(self.tmp, "a")))
        self.assertEqual(m["id"], "demo")
        self.assertEqual(m["permissions"], [])
        self.assertEqual(m["timeout_s"], 600)
        self.assertEqual(m["actions"][0]["inputs"], [])
        g = P.load_manifest(os.path.join(FIX, "good"))
        kinds = [i["type"] for i in g["actions"][0]["inputs"]]
        self.assertEqual(kinds, ["text", "number", "choice"])

    def test_manifest_rejects_bad_id_entry_outside_unknown_permission_long_strings(self):
        bad = [
            dict(id="A"), dict(id="-ab"), dict(id="a"), dict(id="x" * 41), dict(id="ok id"),
            dict(entry="../main.py"), dict(entry="/etc/hosts"), dict(entry="missing.py"), dict(entry="sub/../../x"),
            dict(permissions=["network", "files"]), dict(permissions="network"),
            dict(name="n" * 201), dict(author=""), dict(description=5), dict(version=None),
            dict(schema=2), dict(actions=[]), dict(actions=[{"id": "a"}, {"id": "a"}]),
            dict(actions=[{"id": "a", "inputs": [{"name": "x", "type": "video"}]}]),
            dict(actions=[{"id": "a", "inputs": [{"name": "x", "type": "choice", "choices": []}]}]),
            dict(timeout_s=3601), dict(timeout_s=0),
        ]
        for i, over in enumerate(bad):
            with self.subTest(over=str(over)[:60]):
                with self.assertRaises(P.PluginError):
                    P.load_manifest(write_manifest(os.path.join(self.tmp, "b%d" % i), **over))
        with self.assertRaises(P.PluginError):
            P.load_manifest(os.path.join(FIX, "bad_entry_outside"))
        with self.assertRaises(P.PluginError):
            P.load_manifest(self.tmp)  # no plugin.json

    def test_manifest_entry_symlink_escaping_folder_rejected(self):
        folder = write_manifest(os.path.join(self.tmp, "s"))
        os.remove(os.path.join(folder, "main.py"))
        os.symlink("/etc/hosts", os.path.join(folder, "main.py"))
        with self.assertRaises(P.PluginError):
            P.load_manifest(folder)


class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.plugins = os.path.join(self.tmp, "plugins")

    def test_install_copies_atomically_and_refuses_symlink_huge_duplicate(self):
        pid = P.install(os.path.join(FIX, "good"), self.plugins)
        self.assertEqual(pid, "good")
        self.assertTrue(os.path.isfile(os.path.join(self.plugins, "good", "main.py")))
        self.assertEqual(os.listdir(self.plugins), ["good"], "no temp folders left behind")
        self.assertEqual(P.folder_digest(os.path.join(FIX, "good")), P.folder_digest(os.path.join(self.plugins, "good")))
        with self.assertRaisesRegex(P.PluginError, "already installed"):
            P.install(os.path.join(FIX, "good"), self.plugins)
        with self.assertRaisesRegex(P.PluginError, "link"):
            P.install(os.path.join(FIX, "symlink"), self.plugins)
        # a link to a folder, and a link hidden in a subfolder
        d = copy_fixture("huge", self.tmp)
        os.makedirs(os.path.join(d, "sub"))
        os.symlink(self.tmp, os.path.join(d, "sub", "up"))
        with self.assertRaisesRegex(P.PluginError, "link"):
            P.install(d, self.plugins)
        os.remove(os.path.join(d, "sub", "up"))
        with open(os.path.join(d, "sub", "big.bin"), "wb") as f:   # sparse: costs no disk
            f.truncate(P.MAX_BYTES + 1)
        with self.assertRaisesRegex(P.PluginError, "larger|too big"):
            P.install(d, self.plugins)
        os.remove(os.path.join(d, "sub", "big.bin"))
        for i in range(P.MAX_FILES + 1):
            open(os.path.join(d, "sub", "f%d" % i), "w").close()
        with self.assertRaisesRegex(P.PluginError, "more than"):
            P.install(d, self.plugins)
        self.assertEqual(os.listdir(self.plugins), ["good"], "failed installs leave nothing behind")

    def test_install_and_digest_refuse_hardlinks_and_oversized_folders(self):
        d = copy_fixture("huge", self.tmp)
        os.link(os.path.join(d, "main.py"), os.path.join(self.tmp, "elsewhere.py"))
        with self.assertRaisesRegex(P.PluginError, "hard-linked"):
            P.install(d, self.plugins)
        with self.assertRaisesRegex(P.PluginError, "hard-linked"):
            P.folder_digest(d)
        os.remove(os.path.join(self.tmp, "elsewhere.py"))
        for i in range(P.MAX_FILES + P.MAX_FILES // 4 + 1):   # a hand-copied folder: list/digest must stop early
            open(os.path.join(d, "f%d" % i), "w").close()
        with self.assertRaisesRegex(P.PluginError, "too big"):
            P.folder_digest(d)
        os.makedirs(self.plugins, exist_ok=True)
        shutil.move(d, os.path.join(self.plugins, "huge"))
        item = P.list_plugins(self.plugins)[0]
        self.assertIn("error", item)

    def test_install_refuses_invalid_manifest_and_missing_folder(self):
        with self.assertRaises(P.PluginError):
            P.install(os.path.join(FIX, "bad_entry_outside"), self.plugins)
        with self.assertRaises(P.PluginError):
            P.install(os.path.join(self.tmp, "nope"), self.plugins)


class Digest(unittest.TestCase):
    def test_folder_digest_changes_when_any_file_changes_and_is_stable(self):
        with tempfile.TemporaryDirectory() as t:
            d = copy_fixture("good", t)
            a = P.folder_digest(d)
            self.assertEqual(a, P.folder_digest(d))
            self.assertRegex(a, r"^[0-9a-f]{64}$")
            with open(os.path.join(d, "main.py"), "a") as f:
                f.write("# x\n")
            b = P.folder_digest(d)
            self.assertNotEqual(a, b)
            os.makedirs(os.path.join(d, "sub"))
            c = P.folder_digest(d)
            self.assertNotEqual(b, c)                       # an empty folder counts
            with open(os.path.join(d, "sub", "n.txt"), "w") as f:
                f.write("1")
            e = P.folder_digest(d)
            os.rename(os.path.join(d, "sub", "n.txt"), os.path.join(d, "sub", "m.txt"))
            self.assertNotEqual(e, P.folder_digest(d))      # a rename counts
            open(os.path.join(d, ".DS_Store"), "w").close()
            self.assertEqual(P.folder_digest(d), P.folder_digest(d))

    def test_trust_reset_when_digest_changes(self):
        self.assertFalse(P.needs_trust("abc", "abc"))
        self.assertTrue(P.needs_trust("abc", "abd"))
        self.assertTrue(P.needs_trust(None, "abc"))
        self.assertTrue(P.needs_trust("", ""))


class Env(unittest.TestCase):
    def test_build_env_contains_only_allowlist(self):
        parent = {"HF_TOKEN": "h", "OV_API_KEY": "k", "AWS_SECRET_ACCESS_KEY": "s", "SSH_AUTH_SOCK": "/x",
                  "PATH": "/opt/evil", "HOME": "/Users/me", "LANG": "ru_RU.UTF-8", "PYTHONPATH": "/evil",
                  "OV_OFFLINE": "1"}
        env = P.build_env(parent, "/w", "/d")
        self.assertEqual(set(env), {"PATH", "HOME", "TMPDIR", "LANG", "PYTHONNOUSERSITE", "PYTHONDONTWRITEBYTECODE",
                                    "OV_OFFLINE"})
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual((env["HOME"], env["TMPDIR"], env["OV_OFFLINE"]), ("/d", "/w", "1"))
        self.assertNotIn("secret", json.dumps(env).lower())
        self.assertEqual(P.build_env({}, "/w", "/d")["OV_OFFLINE"], "0")
        self.assertEqual(P.build_env({"LANG": "x; rm -rf"}, "/w", "/d")["LANG"], "en_US.UTF-8")

    def test_command_shape(self):
        self.assertEqual(P.command("/py", "/h.py", "/p", "act", "/s.sb"),
                         ["/usr/bin/sandbox-exec", "-f", "/s.sb", "/py", "/h.py", "--plugin", "/p", "--action", "act"])

    def test_profile_text(self):
        p = P.sandbox_profile("/tmp/w", "/tmp/d", False)
        self.assertIn("(deny network*)", p)
        self.assertIn("(deny file-write*)", p)
        self.assertNotIn("(deny network*)", P.sandbox_profile("/tmp/w", "/tmp/d", True))
        self.assertIn('"/private/tmp/w"', p)   # resolved
        for needle in ("/usr/bin/open", "/usr/bin/osascript", "com.apple.coreservices.launchservicesd", "(deny file-read*"):
            self.assertIn(needle, p)


@unittest.skipUnless(SANDBOX, "sandbox-exec is not available here")
class Sandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = os.path.join(self.tmp, "work")
        self.data = os.path.join(self.tmp, "data")
        os.makedirs(self.work)
        os.makedirs(self.data)

    def run_py(self, code, allow_network=False, read_files=()):
        prof = os.path.join(self.tmp, "p.sb")
        with open(prof, "w") as f:
            f.write(P.sandbox_profile(self.work, self.data, allow_network, None,
                                      P.python_read_roots(sys.executable) + [os.path.dirname(HOST)],
                                      list(read_files) + P.python_read_files(sys.executable)))
        argv = P.command(sys.executable, HOST, self.tmp, "x", prof)[:4] + ["-c", code]
        env = P.build_env({}, self.work, self.data)
        env["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")  # the test interpreter may be a venv shim
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60, cwd=self.work)

    def test_sandbox_blocks_write_outside_work_dir(self):
        out = os.path.join(self.tmp, "outside_cns")
        r = self.run_py("open(%r,'w')" % out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(out))
        r = self.run_py("open('/tmp/x_cns_plugin','w')")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists("/tmp/x_cns_plugin"))
        r = self.run_py("import os; open(os.path.expanduser('~/x_cns_plugin'),'w')")   # HOME is data_dir: allowed
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_py("open(%r,'w').write('ok')" % os.path.join(self.work, "a.txt"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.work, "a.txt")))

    def test_sandbox_blocks_network_unless_allowed(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(5)
        self.addCleanup(srv.close)
        port = srv.getsockname()[1]
        def accept_two():
            try:
                for _ in range(2):
                    srv.accept()
            except OSError:
                pass
        threading.Thread(target=accept_two, daemon=True).start()
        code = "import socket; s=socket.create_connection(('127.0.0.1',%d),timeout=5); s.close()" % port
        self.assertNotEqual(self.run_py(code).returncode, 0)
        r = self.run_py(code, allow_network=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_sandbox_blocks_reading_ssh_folder(self):
        ssh = os.path.join(os.path.realpath(os.path.expanduser("~")), ".ssh")
        if not os.path.isdir(ssh):
            self.skipTest("no ~/.ssh")
        r = self.run_py("import os; os.listdir(%r)" % ssh)
        self.assertNotEqual(r.returncode, 0)


    def home_file(self, name, text="secret"):
        home = os.path.realpath(os.path.expanduser("~"))
        d = os.path.join(home, ".cns_plugin_test_%d" % os.getpid())
        os.makedirs(d, exist_ok=True)
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_sandbox_blocks_reading_home_except_input_files(self):
        secret = self.home_file("secret.txt")
        inp = self.home_file("input.wav", "audio")
        r = self.run_py("print(open(%r).read())" % secret)
        self.assertNotEqual(r.returncode, 0, "a file in ~ must not be readable")
        r = self.run_py("print(open(%r).read())" % inp)
        self.assertNotEqual(r.returncode, 0, "an input file is readable only when it is listed")
        r = self.run_py("print(open(%r).read())" % inp, read_files=[inp])
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "audio"), r.stderr)
        r = self.run_py("import os; os.listdir(os.path.dirname(%r))" % secret)
        self.assertNotEqual(r.returncode, 0, "listing a folder in ~ must fail")
        app = os.path.join(os.path.realpath(os.path.expanduser("~")), "Library/Application Support/Clone'n'Speak")
        if os.path.isdir(app):
            self.assertNotEqual(self.run_py("import os; os.listdir(%r)" % app).returncode, 0)
        # its own folders stay readable
        r = self.run_py("open(%r,'w').write('x'); print(open(%r).read())" % (os.path.join(self.work, "a"), os.path.join(self.work, "a")))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_sandbox_blocks_open_and_osascript(self):
        for prog in ("/usr/bin/open", "/usr/bin/osascript", "/bin/launchctl", "/usr/bin/shortcuts"):
            if not os.path.exists(prog):
                continue
            r = self.run_py("import subprocess,sys\n"
                            "try:\n subprocess.run([%r, '-g', '/dev/null'], timeout=10); sys.exit(0)\n"
                            "except PermissionError: sys.exit(7)\nexcept Exception: sys.exit(8)" % prog)
            self.assertEqual(r.returncode, 7, "%s must not start: %s" % (prog, r.stderr))
        # a binary dropped into the work folder cannot be started either
        r = self.run_py("import shutil,subprocess,sys,os\np=os.path.join(%r,'t')\nshutil.copy('/usr/bin/true',p)\n"
                        "try:\n subprocess.run([p]); sys.exit(0)\nexcept PermissionError: sys.exit(7)" % self.work)
        self.assertEqual(r.returncode, 7, r.stderr)


class Validate(unittest.TestCase):
    def action(self):
        return P.load_manifest(os.path.join(FIX, "good"))["actions"][0]

    def test_validate_inputs(self):
        a = self.action()
        self.assertEqual(P.validate_inputs(a, {}), {"text": "", "n": 3, "kind": "a"})
        self.assertEqual(P.validate_inputs(a, {"text": "x", "n": 10, "kind": "b"})["kind"], "b")
        for bad in ({"n": 11}, {"n": -1}, {"n": "3"}, {"n": True}, {"n": float("nan")}, {"kind": "c"}, {"text": 5},
                    {"zzz": 1}):
            with self.assertRaises(P.PluginError, msg=str(bad)):
                P.validate_inputs(a, bad)
        with self.assertRaises(P.PluginError):
            P.validate_inputs(a, [])
        gain = P.load_manifest(os.path.join(ROOT, "docs", "examples", "plugin-gain"))["actions"][0]
        with self.assertRaises(P.PluginError):
            P.validate_inputs(gain, {})                       # audio is required
        self.assertEqual(P.validate_inputs(gain, {"audio": "/x.wav"})["gain_db"], 6)


PARENT = """
import os, subprocess, sys, time
pidfile, sleeper = sys.argv[1], sys.argv[2]
subprocess.Popen([sys.executable, sleeper, pidfile], start_new_session=True)
with open(pidfile, "a") as f:
    f.write(str(os.getpid()) + "\\n")
time.sleep(60)
"""
SLEEPER = """
import os, sys, time
with open(sys.argv[1], "a") as f:
    f.write(str(os.getpid()) + "\\n")
time.sleep(60)
"""


class Relay(unittest.TestCase):
    RELAY = os.path.join(ROOT, "Sources", "cns_plugin_relay.py")

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def run_relay(self, child_code, timeout=20, work=None):
        work = work or self.tmp
        return subprocess.run([sys.executable, self.RELAY, "--work", work, "--timeout", str(timeout), "--",
                               sys.executable, "-c", child_code], input=b"{}\n", capture_output=True, timeout=60)

    def events(self, r):
        return [json.loads(l) for l in r.stdout.decode().splitlines()]

    def test_relay_drops_forged_outputs_and_keeps_inside_ones(self):
        inside = os.path.join(self.tmp, "ok.txt")
        code = ("import json,sys\nopen(%r,'w').write('x')\n"
                "print(json.dumps({'event':'result','data':{'outputs':[%r,'/etc/hosts','../x'],'text':'t','evil':1}}))"
                % (inside, inside))
        r = self.run_relay(code)
        ev = self.events(r)
        res = [e for e in ev if e["event"] == "result"][0]
        self.assertEqual(res["data"], {"outputs": [inside], "text": "t"})
        self.assertEqual(len([e for e in ev if e["event"] == "log"]), 2)

    def test_relay_drops_partial_outside_and_junk_lines(self):
        code = ("import json\nprint('junk line')\nprint(json.dumps({'event':'partial','path':'/etc/hosts'}))\n"
                "print(json.dumps({'event':'bogus'}))\nprint(json.dumps({'event':'status','msg':'hi'}))")
        ev = self.events(self.run_relay(code))
        self.assertEqual([e["event"] for e in ev if e["event"] != "log"], ["status"])

    def test_relay_reports_exit_code_without_event(self):
        r = self.run_relay("import sys; sys.exit(3)")
        self.assertEqual(r.returncode, 1)
        self.assertIn("exit code 3", self.events(r)[-1]["msg"])

    def pid_alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def tree_scripts(self):
        pidfile = os.path.join(self.tmp, "pids")
        parent, sleeper = os.path.join(self.tmp, "parent.py"), os.path.join(self.tmp, "sleeper.py")
        for path, text in ((parent, PARENT), (sleeper, SLEEPER)):
            with open(path, "w") as f:
                f.write(text)
        return pidfile, [sys.executable, parent, pidfile, sleeper]

    def read_pids(self, pidfile):
        with open(pidfile) as f:
            return [int(x) for x in f.read().split()]

    def test_relay_timeout_kills_the_tree_including_setsid_children(self):
        pidfile, cmd = self.tree_scripts()
        t0 = time.time()
        r = subprocess.run([sys.executable, self.RELAY, "--work", self.tmp, "--timeout", "3", "--"] + cmd,
                           input=b"{}\n", capture_output=True, timeout=60)
        self.assertLess(time.time() - t0, 15)
        self.assertEqual(r.returncode, 1)
        self.assertIn("ran longer", self.events(r)[-1]["msg"])
        time.sleep(0.5)
        pids = self.read_pids(pidfile)
        self.assertEqual(len(pids), 2)
        for pid in pids:
            self.assertFalse(self.pid_alive(pid), "process %d survived the timeout" % pid)

    def test_relay_sigterm_kills_the_tree(self):
        pidfile, cmd = self.tree_scripts()
        p = subprocess.Popen([sys.executable, self.RELAY, "--work", self.tmp, "--timeout", "60", "--"] + cmd,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        p.stdin.write(b"{}\n")
        p.stdin.close()
        for _ in range(100):
            if os.path.exists(pidfile) and len(self.read_pids(pidfile)) == 2:
                break
            time.sleep(0.1)
        time.sleep(1.2)   # let the tree sampler see the detached child
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=15)
        p.stdout.close()
        time.sleep(0.5)
        for pid in self.read_pids(pidfile):
            self.assertFalse(self.pid_alive(pid), "process %d survived Stop" % pid)


class Host(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = os.path.join(self.tmp, "work")
        os.makedirs(self.work)
        self.plugin = os.path.join(FIX, "good")

    def run_host(self, action, inputs=None, plugin=None):
        env = {"PATH": "/usr/bin:/bin", "TMPDIR": self.work, "HOME": self.tmp}
        req = json.dumps({"inputs": inputs or {}, "work_dir": self.work}) + "\n"
        r = subprocess.run([sys.executable, HOST, "--plugin", plugin or self.plugin, "--action", action],
                           input=req, env=env, capture_output=True, text=True, timeout=60)
        events = []
        for line in r.stdout.splitlines():
            events.append(json.loads(line))   # every stdout line must be a protocol event
        return r, events

    def test_host_runs_action_and_streams_events(self):
        r, ev = self.run_host("make", {"text": "hello"})
        self.assertEqual(r.returncode, 0, r.stderr)
        kinds = [e["event"] for e in ev]
        self.assertEqual(kinds, ["status", "progress", "log", "result"])
        self.assertEqual(ev[0]["msg"], "Working")
        self.assertEqual(ev[1]["value"], 0.5)
        out = os.path.join(self.work, "out.txt")
        self.assertEqual(ev[3]["data"]["outputs"], [out])
        self.assertEqual(ev[3]["data"]["text"], "done")
        with open(out) as fh:
            self.assertEqual(fh.read(), "hello")

    def test_host_refuses_output_outside_work_dir(self):
        for action in ("escape_rel", "escape_abs"):
            r, ev = self.run_host(action)
            self.assertEqual(r.returncode, 1)
            self.assertEqual([e["event"] for e in ev], ["error"], action)
            self.assertIn("outside the work folder", ev[0]["msg"])

    def test_host_prints_go_to_stderr(self):
        r, ev = self.run_host("chatty")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([e["event"] for e in ev], ["result"])
        self.assertIn("this is plain print output", r.stderr)
        self.assertIn("raw fd write", r.stderr)

    def test_plugin_crash_reports_error_event(self):
        r, ev = self.run_host("crash")
        self.assertEqual(r.returncode, 1)
        self.assertEqual([e["event"] for e in ev], ["error"])
        self.assertIn("boom", ev[0]["msg"])

    def test_host_rejects_unknown_action_and_bad_request(self):
        r, ev = self.run_host("nope")
        self.assertEqual([e["event"] for e in ev], ["error"])
        r = subprocess.run([sys.executable, HOST, "--plugin", self.plugin, "--action", "make"], input="not json\n",
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(json.loads(r.stdout.splitlines()[0])["event"], "error")

    def test_host_timeout_ends_the_process(self):
        with tempfile.TemporaryDirectory() as t:
            d = write_manifest(os.path.join(t, "slow"), id="slow", timeout_s=1)
            with open(os.path.join(d, "main.py"), "w") as f:
                f.write("import time\ndef run(a, i, c):\n    time.sleep(30)\n")
            r, ev = self.run_host("go", plugin=d)
            self.assertEqual(r.returncode, 1)
            self.assertIn("ran longer", ev[0]["msg"])

    def test_example_plugin_gain_is_valid(self):
        d = os.path.join(ROOT, "docs", "examples", "plugin-gain")
        self.assertEqual(P.load_manifest(d)["id"], "gain")

    @unittest.skipUnless(SANDBOX, "sandbox-exec is not available here")
    def test_example_plugin_gain_runs_in_sandbox(self):
        import wave
        src = os.path.join(self.tmp, "in.wav")
        with wave.open(src, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(8000)
            w.writeframes((b"\x00\x10" * 800))
        d = os.path.join(ROOT, "docs", "examples", "plugin-gain")
        data = os.path.join(self.tmp, "data")
        os.makedirs(data)
        spec = P.launch(sys.executable, HOST, d, "gain", self.work, data, False, os.path.join(self.tmp, "p.sb"), [src])
        argv = spec["argv"]
        self.assertTrue(argv[1].endswith("cns_plugin_relay.py"))
        env = spec["env"]
        env["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")
        req = json.dumps({"inputs": {"audio": src, "gain_db": 6}, "work_dir": self.work}) + "\n"
        r = subprocess.run(argv, input=req, env=env, capture_output=True, text=True, timeout=60)
        ev = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertEqual(ev[-1]["event"], "result", r.stdout + r.stderr)
        with wave.open(ev[-1]["data"]["outputs"][0]) as w:
            frames = w.readframes(w.getnframes())
        self.assertEqual(int.from_bytes(frames[:2], "little"), 0x1fed)   # 0x1000 * 10**(6/20)


class Cli(unittest.TestCase):
    """The app calls cns_plugins.py as a program (list / install / digest / launch)."""
    def cli(self, *args):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "Sources", "cns_plugins.py")] + list(args),
                           capture_output=True, text=True, timeout=60)
        return json.loads(r.stdout)

    def test_cli_install_list_digest_launch(self):
        with tempfile.TemporaryDirectory() as t:
            plugins = os.path.join(t, "plugins")
            self.assertEqual(self.cli("install", os.path.join(FIX, "good"), plugins), {"id": "good"})
            self.assertIn("already installed", self.cli("install", os.path.join(FIX, "good"), plugins)["error"])
            items = self.cli("list", plugins)
            self.assertEqual([i["manifest"]["id"] for i in items], ["good"])
            self.assertEqual(items[0]["digest"], self.cli("digest", os.path.join(plugins, "good"))["digest"])
            work, data = os.path.join(t, "w"), os.path.join(t, "d")
            r = self.cli("launch", "/py", "/h.py", os.path.join(plugins, "good"), "make", work, data, "0", os.path.join(work, "p.sb"), "/in/a.wav")
            i = r["argv"].index("--")
            self.assertEqual(r["argv"][i + 1:i + 4], ["/usr/bin/sandbox-exec", "-f", os.path.join(work, "p.sb")])
            self.assertTrue(r["argv"][1].endswith("cns_plugin_relay.py"))
            self.assertEqual(r["argv"][r["argv"].index("--timeout") + 1], "60")
            self.assertEqual(r["env"]["HOME"], data)
            self.assertIn('(literal "/in/a.wav")', open(os.path.join(work, "p.sb")).read())
            self.assertIn("error", self.cli("nope"))

    def test_cli_list_flags_invalid_and_mismatched_folders(self):
        with tempfile.TemporaryDirectory() as t:
            write_manifest(os.path.join(t, "wrong-name"), id="other")
            os.makedirs(os.path.join(t, "empty"))
            os.makedirs(os.path.join(t, ".install-tmp"))
            items = {i["dir_id"]: i for i in self.cli("list", t)}
            self.assertEqual(set(items), {"wrong-name", "empty"})
            self.assertTrue(all("error" in i for i in items.values()))


class Lightweight(unittest.TestCase):
    def test_module_imports_no_heavy_packages(self):
        code = ("import sys; sys.path.insert(0, %r); import cns_plugins; "
                "bad = [m for m in ('numpy', 'torch', 'scipy', 'soundfile') if m in sys.modules]; "
                "sys.exit(1 if bad else 0)" % os.path.join(ROOT, "Sources"))
        self.assertEqual(subprocess.run([sys.executable, "-c", code]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
