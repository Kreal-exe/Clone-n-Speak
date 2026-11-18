"""Builds and runs tests/objc/realtime_test.m (the lock-free ring, block assembler, latency statistics, host-time math).

The binary prints "PASS <case>" / "FAIL <case>"; every Python test below checks one case, so a failure names the case.
Skipped without clang.
"""
import os
import shutil
import subprocess
import tempfile
import unittest

try:
    from test_objc import FRAMEWORKS, ROOT, deps_of
except ImportError:   # run as tests.test_realtime_objc from the repository root
    from tests.test_objc import FRAMEWORKS, ROOT, deps_of

CASES = ["testRingWrapAndBlockAssemblyExact", "testBlockSizeRoundsTo480", "testUnderrunReturnsSilenceAndCounts",
         "testOverrunDropsOldestToTarget", "testLatencyStatsP50P95", "testHostTimeToMs"]
RESULT = {}


def build_and_run():
    path = os.path.join(ROOT, "tests", "objc", "realtime_test.m")
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, "realtime_test")
        fw = [arg for f in FRAMEWORKS for arg in ("-framework", f)]
        cmd = ["clang", "-fobjc-arc", "-Wall", "-Werror", "-mmacosx-version-min=13.0", *fw, "-I", os.path.join(ROOT, "Sources"),
               *deps_of(path), path, "-o", exe]
        b = subprocess.run(cmd, capture_output=True, text=True)
        if b.returncode != 0:
            return {"build": b.stderr}
        r = subprocess.run([exe], capture_output=True, text=True, timeout=120, cwd=ROOT)
        out = {}
        for line in r.stdout.splitlines():
            if line.startswith(("PASS ", "FAIL ")):
                out[line[5:]] = line[:4]
        out["stderr"] = r.stderr
        return out


@unittest.skipUnless(shutil.which("clang"), "clang not available")
class RealtimeObjCTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        RESULT.update(build_and_run())

    def check(self, name):
        self.assertNotIn("build", RESULT, RESULT.get("build"))
        self.assertEqual(RESULT.get(name), "PASS", RESULT.get("stderr"))


for _n in CASES:
    setattr(RealtimeObjCTests, "test_" + _n, (lambda n: lambda self: self.check(n))(_n))

if __name__ == "__main__":
    unittest.main()
