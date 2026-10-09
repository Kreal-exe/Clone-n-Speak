#!/usr/bin/env python3
"""Release notes for a version: its CHANGELOG.md section plus the install instructions.

  tools/release_notes.py 1.0.1 > notes.md      exits with an error when the changelog has no "## 1.0.1" section

The release workflow calls this, so a version can only be published once its changes are written down.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

FOOTER = """### Install
Download **CloneNSpeak-{version}.dmg** and drag the app to Applications. The build is not notarized, so macOS says it “could not verify” the app — remove the quarantine flag and launch it:

```bash
xattr -dr com.apple.quarantine "/Applications/Clone'n'Speak.app"
open "/Applications/Clone'n'Speak.app"
```

Or: System Settings → Privacy & Security → **Open Anyway**.
Requires Apple Silicon (M1+) and macOS 13+. Voices, settings and downloaded models from earlier versions are kept.

---
**По-русски:** скачайте DMG и перетащите приложение в «Программы». Если macOS пишет «не удалось подтвердить», выполните две команды выше или нажмите «Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть».
"""


def section(changelog, version):
    """Text under "## <version>" up to the next "## " heading, or None."""
    m = re.search(rf"^## {re.escape(version)}[ \t]*\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
    if not m or not m.group(1).strip():
        return None
    # GitHub shows every newline of a release body as a line break: undo the changelog's hard wrapping
    return re.sub(r"\n[ \t]+(?![ \t]|[-*+] |\d+\. )", " ", m.group(1).strip())


def notes(version, changelog=None):
    if changelog is None:
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    body = section(changelog, version)
    if body is None:
        raise SystemExit(f"CHANGELOG.md has no \"## {version}\" section — describe the release there first")
    return f"{body}\n\n{FOOTER.format(version=version)}"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.stdout.write(notes(sys.argv[1].lstrip("v")))
