"""Builds and runs every tests/objc/*_test.m.

The first line of a test file lists the sources it needs: `// deps: A.m B.m` (files in Sources/). Each test is a command-line
program with its own main(); exit status 0 = pass. themes.json is copied next to the binary so OVTheme finds its palettes.
"""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
FRAMEWORKS = ["Cocoa", "AVFoundation", "AVFAudio", "UniformTypeIdentifiers", "NaturalLanguage", "QuartzCore"]


def deps_of(path):
    first = path.read_text(encoding="utf-8").splitlines()[0]
    return first.split("deps:", 1)[1].split() if "deps:" in first else []


class ObjCTests(unittest.TestCase):
    pass


def make_test(path):
    def run(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = pathlib.Path(tmp) / path.stem
            cmd = ["clang", "-fobjc-arc", "-mmacosx-version-min=13.0", "-Wall", "-Werror", "-I", str(ROOT / "Sources")]
            for fw in FRAMEWORKS:
                cmd += ["-framework", fw]
            cmd += [str(path)] + [str(ROOT / "Sources" / d) for d in deps_of(path)] + ["-o", str(exe)]
            build = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            shutil.copy(ROOT / "Resources" / "themes.json", pathlib.Path(tmp) / "themes.json")
            out = subprocess.run([str(exe)], capture_output=True, text=True, cwd=tmp, timeout=120)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
    return run


for _p in sorted((ROOT / "tests" / "objc").glob("*_test.m")):
    setattr(ObjCTests, "test_" + _p.stem, make_test(_p))

if __name__ == "__main__":
    unittest.main()
