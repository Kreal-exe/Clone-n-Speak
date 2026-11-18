"""Builds and runs tests/objc/pro_run_test.m and tests/objc/engines_test.m (the pro-run preflight and the engine manager).

Both print "PASS <case>" / "FAIL <case>" per case; every Python test below checks one case, so a failure names the case.
Compiled the way tests/test_objc.py does (the first line of each file lists its sources). Skipped without clang.
"""
import os
import shutil
import subprocess
import tempfile
import unittest

try:
    from test_objc import FRAMEWORKS, ROOT, deps_of
except ImportError:   # run as tests.test_pro_run from the repository root
    from tests.test_objc import FRAMEWORKS, ROOT, deps_of

FILES = ("pro_run_test.m", "engines_test.m")
RESULTS = {}
OUTPUT = {}

PRO_RUN = ["test_pro_job_unloads_main_models_first", "test_declined_pro_run_keeps_models_loaded",
           "test_16gb_mac_skips_confirm_but_still_unloads", "test_low_memory_warns_with_numbers",
           "test_train_falls_back_to_batch_2_when_tight", "test_offline_blocks_edge_and_youtube_before_anything",
           "test_two_pro_jobs_never_run_together", "test_before_start_unloads_when_started_from_queue",
           "test_light_job_checks_memory_without_unloading"]
ENGINES = ["testEnginesStateFromStatusJson", "testInstallRefusedWhileProJobActive", "testLayoutSplitMapsLogicalNames",
           "testPeakBytesFromStatus", "testSpecForProKindRunsUnderSandbox", "testSpecEnvironmentIsADictionary",
           "testSpecRunsThroughTheJobManager", "testSocketConnectsThroughALongPath", "testKindTableCoversTheContract",
           "testWorkerGuardBlocksModelLoading", "testKeepStdinOpenUntilStop"]


def build_and_run(name):
    path = os.path.join(ROOT, "tests", "objc", name)
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, name[:-2])
        fw = [arg for f in FRAMEWORKS for arg in ("-framework", f)]
        cmd = ["clang", "-fobjc-arc", "-Wall", "-mmacosx-version-min=13.0", *fw, "-I", os.path.join(ROOT, "Sources"),
               *deps_of(path), path, "-o", exe]
        b = subprocess.run(cmd, capture_output=True, text=True)
        if b.returncode != 0:
            OUTPUT[name] = b.stderr
            RESULTS[name] = {}
            return
        themes = os.path.join(ROOT, "Resources", "themes.json")
        if os.path.exists(themes):
            shutil.copy(themes, os.path.join(tmp, "themes.json"))
        r = subprocess.run([exe], capture_output=True, text=True, timeout=300, cwd=ROOT)
    OUTPUT[name] = r.stdout + r.stderr
    RESULTS[name] = {ln.split(" ", 1)[1]: ln.split(" ", 1)[0] for ln in r.stdout.splitlines() if ln.startswith(("PASS ", "FAIL "))}


@unittest.skipUnless(shutil.which("clang"), "clang not available")
class ProRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for f in FILES:
            build_and_run(f)

    def check(self, file, case):
        self.assertEqual(RESULTS[file].get(case), "PASS", OUTPUT[file])


def _make(file, case):
    return lambda self: self.check(file, case)


for _case in PRO_RUN:
    setattr(ProRunTests, _case, _make("pro_run_test.m", _case))
for _case in ENGINES:
    setattr(ProRunTests, "test_engines_" + _case[4:], _make("engines_test.m", _case))

if __name__ == "__main__":
    unittest.main()
