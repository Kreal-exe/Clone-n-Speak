"""Unit tests for tools/release_notes.py (the notes the release workflow publishes).

Run: python3 -m unittest discover -s tests
"""
import importlib.util
import pathlib
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "tools" / "release_notes.py"
_spec = importlib.util.spec_from_file_location("release_notes", _path)
release_notes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_notes)

CHANGELOG = """# Changelog

## 1.2.0

- New thing
- Another one

## 1.1.0

- Old thing

## 1.0.9
"""


class ReleaseNotes(unittest.TestCase):
    def test_takes_only_its_own_section(self):
        text = release_notes.notes("1.2.0", CHANGELOG)
        self.assertTrue(text.startswith("- New thing\n- Another one\n\n### Install"))
        self.assertNotIn("Old thing", text)
        self.assertIn("CloneNSpeak-1.2.0.dmg", text)
        self.assertIn("- Old thing", release_notes.notes("1.1.0", CHANGELOG))

    def test_wrapped_lines_are_joined(self):
        text = release_notes.notes("2.0.0", "## 2.0.0\n\n- A long item that the changelog\n  wraps onto a second line.\n  - nested item\n- Next\n")
        self.assertTrue(text.startswith("- A long item that the changelog wraps onto a second line.\n  - nested item\n- Next\n"))

    def test_version_must_be_described(self):
        for version in ("1.3.0", "1.0.9", "1.2"):  # missing, empty, and a prefix of another version
            with self.assertRaises(SystemExit):
                release_notes.notes(version, CHANGELOG)

    def test_the_real_changelog_covers_the_current_version(self):
        plist = (_path.parent.parent / "Sources" / "Info.plist").read_text(encoding="utf-8")
        version = plist.split("<key>CFBundleShortVersionString</key><string>")[1].split("<")[0]
        self.assertIn("### Install", release_notes.notes(version))


if __name__ == "__main__":
    unittest.main()
