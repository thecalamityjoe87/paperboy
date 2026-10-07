#!/usr/bin/env python3
"""Work out each flag's shade levels for make_mono_flags.py.

Renders the original color flag, takes its main colors (the four largest by
area), and gives them evenly spaced shades by brightness: darkest solid, the
lightest non-white one at LIGHTEST, near-white transparent. A flag with one
main color also counts its most common other color, so an emblem (Morocco's
star) gets its own shade. Writes levels.json in the current directory.

Normally run through generate_flags.sh. Needs Pillow.

usage: flag_levels.py RENDER_BIN CC [CC ...]
"""
import json, os, subprocess, sys
from collections import Counter

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_mono_flags import fetch  # noqa: E402

WHITE = 0.8      # luminance at or above this: transparent
LIGHTEST = 0.35  # shade for the lightest non-white main color
MERGE = 0.02     # brightnesses closer than this count as one color


def lin(v):
    v /= 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def lum(c):
    r, g, b = c
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def distinct(values):
    out = []
    for v in sorted(values):
        if v >= WHITE or (out and v - out[-1] < MERGE):
            continue
        out.append(v)
    return out


def levels_for(png):
    im = Image.open(png).convert("RGBA")
    counts = Counter((r, g, b) for r, g, b, a in im.get_flattened_data() if a >= 128)
    total = sum(counts.values())
    ranked = counts.most_common()
    main = [c for c, n in ranked[:4] if n / total >= 0.02]
    ls = distinct(lum(c) for c in main)
    if len(ls) < 2:
        for c, n in ranked:
            v = lum(c)
            if v < WHITE and all(abs(v - x) >= MERGE for x in ls) and n / total >= 0.002:
                ls = distinct(ls + [v])
                break
    n = len(ls)
    pts = [[round(v, 4), round(1.0 if n == 1 else 1.0 - (1.0 - LIGHTEST) * i / (n - 1), 3)]
           for i, v in enumerate(ls)]
    pts.append([WHITE, 0.0])
    return pts


def main():
    render, codes = sys.argv[1], [c.lower() for c in sys.argv[2:]]
    os.makedirs("flag-renders", exist_ok=True)
    args = []
    for cc in codes:
        fetch(cc)
        args += [f"flag-cache/{cc}.svg", f"flag-renders/{cc}.png"]
    subprocess.run([render] + args, check=True)
    result = {cc: levels_for(f"flag-renders/{cc}.png") for cc in codes}
    with open("levels.json", "w") as f:
        json.dump(result, f)
    print(f"levels for {len(result)} flags")


if __name__ == "__main__":
    main()
