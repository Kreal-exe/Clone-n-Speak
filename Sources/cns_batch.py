"""Text splitting for batch synthesis: a text or a file becomes numbered items, each with a file name.
Standard library only; Python 3.9 compatible."""
import os
import re

import cns_core as core

MAX_ITEMS = 500
MAX_CHARS = 8000
MAX_FILE_BYTES = 1024 * 1024
MODES = ("whole", "lines", "paragraphs", "srt")
SLUG_MAX = 40

_TIME = re.compile(r"(\d+):(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?")


def _bad(message):
    raise core.AudioInputError("bad_param", message)


def _seconds(m):
    frac = (m.group(4) or "0").ljust(3, "0")
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(frac) / 1000.0


def clean_markdown(text):
    text = re.sub(r"^ {0,3}(```|~~~).*?^ {0,3}\1[ \t]*$", "", text, flags=re.S | re.M)
    text = re.sub(r"^ {0,3}(```|~~~).*\Z", "", text, flags=re.S | re.M)  # an unclosed fence
    out = []
    for line in text.split("\n"):
        if re.fullmatch(r"\s*([-*_])(\s*\1){2,}\s*", line):
            out.append("")
            continue
        line = re.sub(r"^\s*(#{1,6}\s+|>+\s?|[-*+]\s+|\d+[.)]\s+)", "", line)
        line = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", line)
        line = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", line)
        line = re.sub(r"`([^`]*)`", r"\1", line)
        line = re.sub(r"(\*\*|__)(.+?)\1", r"\2", line)
        line = re.sub(r"(?<![\w*])([*_])(?=\S)(.+?)(?<=\S)\1(?![\w*])", r"\2", line)
        line = re.sub(r"~~(.+?)~~", r"\1", line)
        out.append(line)
    return "\n".join(out)


def slugify(text):
    chars = [c.lower() if c.isalnum() else "-" for c in text]
    slug = re.sub(r"-+", "-", "".join(chars)).strip("-")[:SLUG_MAX].strip("-")
    return slug or "item"


def _parse_srt(text):
    items = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = [l.strip() for l in block.split("\n") if l.strip()]
        timing = next((i for i, l in enumerate(lines) if "-->" in l), None)
        if timing is None:
            continue
        a, _, b = lines[timing].partition("-->")
        ma, mb = _TIME.search(a), _TIME.search(b)
        if not ma or not mb:
            continue
        body = " ".join(lines[timing + 1:]).strip()
        if body:
            items.append({"text": body, "start": _seconds(ma), "end": _seconds(mb)})
    return items


def split_items(text, mode, ext=".txt"):
    if mode not in MODES:
        _bad("Choose how to split the text: whole, lines, paragraphs or srt.")
    text = (text or "").lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n")
    if str(ext).lower() in (".md", ".markdown", "md"):
        text = clean_markdown(text)
    if mode == "srt":
        raw = _parse_srt(text)
    elif mode == "whole":
        raw = [{"text": " ".join(text.split())}]
    elif mode == "lines":
        raw = [{"text": " ".join(l.split())} for l in text.split("\n")]
    else:
        raw = [{"text": " ".join(p.split())} for p in re.split(r"\n\s*\n", text)]
    raw = [r for r in raw if r["text"]]
    if not raw:
        raise core.AudioInputError("empty", "There is no text to speak. Choose a file or paste text that has words in it.")
    if len(raw) > MAX_ITEMS:
        _bad("Split the file: up to %d items per batch (it has %d)." % (MAX_ITEMS, len(raw)))
    items = []
    for i, r in enumerate(raw, 1):
        if len(r["text"]) > MAX_CHARS:
            _bad("Item %d is %d characters long. Split it: the limit is %d characters per item."
                 % (i, len(r["text"]), MAX_CHARS))
        r["index"] = i
        r["slug"] = slugify(r["text"])
        items.append(r)
    return items


def output_names(items, ext):
    ext = str(ext).lstrip(".") or "wav"
    seen = {}
    names = []
    for it in items:
        slug = it.get("slug") or slugify(it.get("text", ""))
        n = seen.get(slug, 0) + 1
        seen[slug] = n
        names.append("%03d-%s%s.%s" % (it["index"], slug, "" if n == 1 else "-%d" % n, ext))
    return names


def _decode(data):
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16")
    if b"\x00" in data:
        _bad("Save the file as UTF-8 and try again.")
    return data.decode("utf-8-sig")


def cmd_batch_plan(req):
    mode = req.get("mode", "lines")
    ext = ".txt"
    if req.get("path"):
        path = str(req["path"])
        ext = os.path.splitext(path)[1].lower() or ".txt"
        try:
            size = os.path.getsize(path)
        except OSError:
            raise core.AudioInputError("empty", "The file could not be opened. Choose an existing text file.")
        if size == 0:
            raise core.AudioInputError("empty", "The file is empty. Choose a file that has text in it.")
        if size > MAX_FILE_BYTES:
            _bad("The file is larger than 1 MB. Split the file into smaller parts.")
        with open(path, "rb") as f:
            data = f.read()
        try:
            text = _decode(data)
        except UnicodeError:
            _bad("Save the file as UTF-8 and try again.")
    elif isinstance(req.get("text"), str):
        text = req["text"]
    else:
        _bad("Choose a text file or paste the text.")
    items = split_items(text, mode, ext)
    return {"items": items, "names": output_names(items, req.get("ext") or "wav"), "warnings": []}


COMMANDS = {"batch_plan": cmd_batch_plan}
