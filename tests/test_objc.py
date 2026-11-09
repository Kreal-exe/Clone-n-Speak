"""Builds and runs every tests/objc/*_test.m (Foundation-level ObjC logic, no AppKit pages).

Contract: the first line of each test file is `// deps: A.m B.m` -- sources under Sources/ that are compiled
together with it. Each test is a plain main() that prints failures and exits non-zero. Skipped without clang.
"""
import glob
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMEWORKS = ["Foundation", "AVFoundation", "CoreMedia", "CoreVideo", "AudioToolbox"]


def _deps(path):
    with open(path, encoding="utf-8") as f:
        first = f.readline().strip()
    if not first.startswith("// deps:"):
        return []
    return first[len("// deps:"):].split()


@unittest.skipUnless(shutil.which("clang"), "clang not available")
class ObjCTests(unittest.TestCase):
    def test_all(self):
        files = sorted(glob.glob(os.path.join(ROOT, "tests", "objc", "*_test.m")))
        self.assertTrue(files, "no tests/objc/*_test.m found")
        for path in files:
            name = os.path.basename(path)[:-2]
            with self.subTest(name):
                with tempfile.TemporaryDirectory() as tmp:
                    exe = os.path.join(tmp, name)
                    cmd = ["clang", "-fobjc-arc", "-Wall", "-Werror", "-DOV_TESTING=1", "-I", os.path.join(ROOT, "Sources")]
                    for fw in FRAMEWORKS:
                        cmd += ["-framework", fw]
                    cmd += [os.path.join(ROOT, "Sources", d) for d in _deps(path)] + [path, "-o", exe]
                    build = subprocess.run(cmd, capture_output=True, text=True)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    run = subprocess.run([exe], capture_output=True, text=True, cwd=ROOT, timeout=300)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
