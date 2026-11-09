#!/usr/bin/env python3
"""Compare two snapshots: snapdiff.py a.png b.png [--max-diff-pct 0.1] [--ignore x,y,w,h ...]

Prints the share of pixels whose any channel differs by more than 6/255.
Exit code 0 when the share is within the limit, 1 otherwise (also when the sizes differ).
Run with ~/.claude/skills-deps/py/bin/python (Pillow).
"""
import argparse
import sys

from PIL import Image, ImageChops

CHANNEL_THRESHOLD = 6


def diff_pct(a_path, b_path, ignore=()):
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        return None, f"size mismatch: {a.size[0]}x{a.size[1]} vs {b.size[0]}x{b.size[1]}"
    diff = ImageChops.difference(a, b)
    # a pixel differs when its largest channel difference exceeds the threshold
    r, g, bl = diff.split()
    biggest = ImageChops.lighter(ImageChops.lighter(r, g), bl)
    mask = biggest.point(lambda v: 255 if v > CHANNEL_THRESHOLD else 0)
    for x, y, w, h in ignore:   # ignored rectangles count as equal
        mask.paste(0, (x, y, x + w, y + h))
    changed = mask.histogram()[255]
    return 100.0 * changed / (a.size[0] * a.size[1]), None


def parse_rect(text):
    parts = [int(v) for v in text.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("--ignore wants x,y,w,h")
    return tuple(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--max-diff-pct", type=float, default=0.1)
    ap.add_argument("--ignore", action="append", default=[], type=parse_rect, metavar="x,y,w,h",
                    help="pixel rectangle to leave out of the comparison (repeatable)")
    args = ap.parse_args()
    pct, err = diff_pct(args.a, args.b, args.ignore)
    if err:
        print(err)
        return 1
    ok = pct <= args.max_diff_pct
    print(f"{pct:.3f}% of pixels differ (limit {args.max_diff_pct}%) {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
