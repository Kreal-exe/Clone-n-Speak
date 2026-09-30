#!/usr/bin/env python3
"""Localization helper.

  tools/strings.py merge   merge Resources/ru.lproj/fragments/*.strings into Localizable.strings
  tools/strings.py check   fail if an L(@"...") key in Sources/ has no Russian translation,
                           or if a translation changes the format specifiers
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RU = ROOT / "Resources" / "ru.lproj"
TABLE = RU / "Localizable.strings"

KEY_RE = re.compile(r'L\(\s*((?:@"(?:[^"\\]|\\.)*"\s*)+)\)')  # also L(@"a" @"b")
PIECE_RE = re.compile(r'@"((?:[^"\\]|\\.)*)"')
SPEC_RE = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:l{0,2}|h{0,2}|z|q)?[@dDiuUxXoOfeEgGcCsSpaA%]")


def load(path):
    """Parse an old-style .strings file (plutil makes sure it is valid)."""
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"{path}: {out.stderr.strip()}")
    import json
    return json.loads(out.stdout)


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def unescape(s):
    return s.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in s else s


def source_keys():
    keys = set()
    for f in SOURCES.glob("*.m"):
        for m in KEY_RE.finditer(f.read_text(encoding="utf-8")):
            keys.add(unescape("".join(PIECE_RE.findall(m.group(1)))))
    return keys


def write(table):
    lines = ["/* Russian UI strings. Keys are the English text used in L(@\"…\"). */", ""]
    lines += [f"{quote(k)} = {quote(v)};" for k, v in sorted(table.items(), key=lambda kv: kv[0].lower())]
    TABLE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def merge():
    table = load(TABLE) if TABLE.exists() else {}
    frags = sorted((RU / "fragments").glob("*.strings"))
    for f in frags:
        for k, v in load(f).items():
            if k in table and table[k] != v:
                print(f"note: {f.name} overrides {k!r}: {table[k]!r} → {v!r}")
            table[k] = v
    write(table)
    print(f"{TABLE.relative_to(ROOT)}: {len(table)} strings from {len(frags)} fragments")


def check():
    table = load(TABLE) if TABLE.exists() else {}
    keys = source_keys()
    missing = sorted(k for k in keys if k not in table)
    bad = sorted(k for k in keys if k in table and sorted(SPEC_RE.findall(k)) != sorted(SPEC_RE.findall(table[k])))
    unused = sorted(k for k in table if k not in keys)
    for k in missing:
        print(f"missing ru: {k!r}")
    for k in bad:
        print(f"format mismatch: {k!r} → {table[k]!r}")
    if unused:
        print(f"({len(unused)} unused translations)")
    print(f"{len(keys)} keys, {len(missing)} missing, {len(bad)} format mismatches")
    return 1 if missing or bad else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "merge":
        merge()
    else:
        sys.exit(check())
