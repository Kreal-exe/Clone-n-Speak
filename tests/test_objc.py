"""Builds and runs every tests/objc/*_test.m.

Each test file's first line is `// deps: A.m B.m` (sources relative to Sources/). They are compiled together with
the test using clang with ARC and the frameworks below, run from the repository root with Resources/themes.json next
to the binary; a non-zero exit fails the test. Skipped without clang.
"""
import glob
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = sorted(glob.glob(os.path.join(ROOT, "tests", "objc", "*_test.m")))
FRAMEWORKS = ["Foundation", "Cocoa", "AVFoundation", "AVFAudio", "CoreMedia", "CoreVideo", "AudioToolbox",
              "UniformTypeIdentifiers", "NaturalLanguage", "QuartzCore"]


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
        themes = os.path.join(ROOT, "Resources", "themes.json")
        for path in TESTS:
            name = os.path.basename(path)[:-2]
            with self.subTest(name):
                with tempfile.TemporaryDirectory() as tmp:
                    exe = os.path.join(tmp, name)
                    fw = [arg for f in FRAMEWORKS for arg in ("-framework", f)]
                    cmd = ["clang", "-fobjc-arc", "-Wall", "-mmacosx-version-min=13.0", *fw,
                           "-I", os.path.join(ROOT, "Sources"), *deps_of(path), path, "-o", exe]
                    b = subprocess.run(cmd, capture_output=True, text=True)
                    self.assertEqual(b.returncode, 0, b.stderr)
                    if os.path.exists(themes):
                        shutil.copy(themes, os.path.join(tmp, "themes.json"))
                    r = subprocess.run([exe], capture_output=True, text=True, timeout=300, cwd=ROOT)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
