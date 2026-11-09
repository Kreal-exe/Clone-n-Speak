import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from PIL import Image
except ImportError:   # CI and the app runtime have no Pillow
    Image = None

ROOT = Path(__file__).resolve().parent.parent
PY = Path.home() / ".claude" / "skills-deps" / "py" / "bin" / "python"
SCRIPT = ROOT / "tools" / "snapdiff.py"


def run(a, b, *extra):
    return subprocess.run([str(PY), str(SCRIPT), str(a), str(b), *extra], capture_output=True, text=True)


@unittest.skipUnless(Image is not None and PY.exists(), "needs Pillow and the skills-deps Python")
class SnapDiffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def image(self, name, size=(100, 100), color=(20, 30, 40)):
        p = self.dir / name
        Image.new("RGB", size, color).save(p)
        return p

    def test_identical_images_pass(self):
        r = run(self.image("a.png"), self.image("b.png"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0.000", r.stdout)

    def test_one_percent_changed_fails_at_0_1(self):
        a = self.image("a.png")
        img = Image.open(a).copy()
        for x in range(10):
            for y in range(10):
                img.putpixel((x, y), (200, 30, 40))   # 100 of 10000 pixels = 1 %
        b = self.dir / "b.png"
        img.save(b)
        r = run(a, b, "--max-diff-pct", "0.1")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("1.000", r.stdout)

    def test_size_mismatch_fails(self):
        r = run(self.image("a.png"), self.image("b.png", size=(100, 101)))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_small_channel_noise_is_ignored(self):
        r = run(self.image("a.png"), self.image("b.png", color=(24, 34, 44)))   # +4 per channel, below 6
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_ignore_rectangles_are_left_out(self):
        a = self.image("a.png")
        img = Image.open(a).copy()
        for x in range(10):
            for y in range(10):
                img.putpixel((x, y), (200, 30, 40))
        for x in range(50, 55):
            for y in range(50, 55):
                img.putpixel((x, y), (200, 30, 40))
        b = self.dir / "b.png"
        img.save(b)
        self.assertEqual(run(a, b).returncode, 1)
        r = run(a, b, "--ignore", "0,0,10,10", "--ignore", "50,50,5,5")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
