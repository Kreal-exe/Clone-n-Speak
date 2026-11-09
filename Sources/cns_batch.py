"""Text splitting for batch synthesis: a text or a file becomes numbered items, each with a file name.
Standard library only; Python 3.9 compatible."""
import os
import re
from typing import NoReturn

import cns_core as core

MAX_ITEMS = 500
MAX_CHARS = 8000
MAX_FILE_BYTES = 1024 * 1024
MODES = ("whole", "lines", "paragraphs", "srt")
SLUG_MAX = 40
INLINE_MAX = 4000

_TIME = re.compile(r"(\d+):(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?")


def _bad(message) -> NoReturn:
    raise core.AudioInputError("bad_param", message)


def _seconds(m):
    frac = (m.group(4) or "0").ljust(3, "0")
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(frac) / 1000.0


def _strip_fences(text):
    """Drops fenced code blocks line by line (an unclosed fence runs to the end)."""
    out, fence = [], None
    for line in text.split("\n"):
        stripped = line.lstrip(" ")
        marker = stripped[:3] if stripped[:3] in ("```", "~~~") and len(line) - len(stripped) <= 3 else None
        if fence is None:
            if marker:
                fence = marker
            else:
                out.append(line)
        elif marker == fence:
            fence = None
    return "\n".join(out)


def clean_markdown(text):
    out = []
    for line in _strip_fences(text).split("\n"):
        if re.fullmatch(r"\s*([-*_])(\s*\1){2,}\s*", line):
            out.append("")
            continue
        line = re.sub(r"^\s*(#{1,6}\s+|>+\s?|[-*+]\s+|\d+[.)]\s+)", "", line)
        if len(line) <= INLINE_MAX:  # inline patterns are bounded, and skipped on absurd lines
            line = re.sub(r"!\[([^\]]{0,200})\]\([^)]{0,500}\)", r"\1", line)
            line = re.sub(r"\[([^\]]{0,200})\]\([^)]{0,500}\)", r"\1", line)
            line = re.sub(r"`([^`]{0,200})`", r"\1", line)
            line = re.sub(r"(\*\*|__)(.{1,200}?)\1", r"\2", line)
            line = re.sub(r"(?<![\w*])([*_])(?=\S)(.{1,200}?)(?<=\S)\1(?![\w*])", r"\2", line)
            line = re.sub(r"~~(.{1,200}?)~~", r"\1", line)
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
            if _seconds(mb) < _seconds(ma):
                _bad("A subtitle ends before it starts (%s). Fix the timings in the SRT file."
                     % lines[timing])
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


def _check_ext(ext):
    ext = str(ext or "wav").lstrip(".").lower()
    if not re.fullmatch(r"[a-z0-9]{1,5}", ext):
        _bad("Choose a valid file type such as wav, m4a or flac.")
    return ext


def output_names(items, ext):
    ext = _check_ext(ext)
    seen = {}
    names = []
    for it in items:
        slug = slugify(it.get("slug") or it.get("text", ""))
        n = seen.get(slug, 0) + 1
        seen[slug] = n
        names.append("%03d-%s%s.%s" % (int(it["index"]), slug, "" if n == 1 else "-%d" % n, ext))
    return names


def _decode(data):
    if data[:4] in (b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff"):
        text = data.decode("utf-32")
    elif data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = data.decode("utf-16")
    else:
        text = data.decode("utf-8-sig")
    if "\x00" in text:
        _bad("Save the file as UTF-8 and try again.")
    return text


def cmd_batch_plan(req):
    mode = req.get("mode") or "lines"
    out_ext = _check_ext(req.get("ext"))
    ext = ".txt"
    if req.get("path"):
        path = str(req["path"])
        ext = os.path.splitext(path)[1].lower() or ".txt"
        try:
            size = os.path.getsize(path)
        except OSError:
            raise core.AudioInputError("empty", "The file could not be opened. Choose an existing text file.")
        if not os.path.isfile(path):
            _bad("Choose a text file, not a folder.")
        if size == 0:
            raise core.AudioInputError("empty", "The file is empty. Choose a file that has text in it.")
        if size > MAX_FILE_BYTES:
            _bad("The file is larger than 1 MB. Split the file into smaller parts.")
        try:
            with open(path, "rb") as f:
                data = f.read(MAX_FILE_BYTES + 1)
        except OSError:
            raise core.AudioInputError("empty", "The file could not be read. Check that you may open it, or choose another file.")
        if len(data) > MAX_FILE_BYTES:
            _bad("The file is larger than 1 MB. Split the file into smaller parts.")
        try:
            text = _decode(data)
        except UnicodeError:
            _bad("Save the file as UTF-8 and try again.")
    elif isinstance(req.get("text"), str):
        text = req["text"]
    else:
        _bad("Choose a text file or paste the text.")
    items = split_items(text, mode, ext)
    return {"items": items, "names": output_names(items, out_ext), "warnings": []}


COMMANDS = {"batch_plan": cmd_batch_plan}
