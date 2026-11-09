"""Builds and runs every tests/objc/*_test.m.

Each test file's first line is `// deps: A.m B.m` (sources relative to Sources/). They are compiled together with
the test using clang with ARC and Foundation + AVFoundation, and run; a non-zero exit fails the test.
Skipped without clang.
"""
import glob
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = sorted(glob.glob(os.path.join(ROOT, "tests", "objc", "*_test.m")))


def deps_of(path):
    with open(path, encoding="utf-8") as f:
        first = f.readline().strip()
    if not first.startswith("// deps:"):
        return []
    return [os.path.join(ROOT, "Sources", d) for d in first[len("// deps:"):].split()]


@unittest.skipUnless(shutil.which("clang"), "clang not available")
class ObjCTests(unittest.TestCase):
    def test_all(self):
        self.assertTrue(TESTS, "no tests/objc/*_test.m")
        for path in TESTS:
            name = os.path.basename(path)[:-2]
            with self.subTest(name):
                with tempfile.TemporaryDirectory() as tmp:
                    exe = os.path.join(tmp, name)
                    cmd = ["clang", "-fobjc-arc", "-Wall", "-framework", "Foundation", "-framework", "AVFoundation",
                           "-I", os.path.join(ROOT, "Sources"), *deps_of(path), path, "-o", exe]
                    b = subprocess.run(cmd, capture_output=True, text=True)
                    self.assertEqual(b.returncode, 0, b.stderr)
                    r = subprocess.run([exe], capture_output=True, text=True, timeout=300)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
