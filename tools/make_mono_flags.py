#!/usr/bin/env python3
"""Turn lipis/flag-icons (MIT) 4x3 flags into Paperboy's 24x24 single-color
sidebar icons: flag-<cc>-mono.svg (black) and flag-<cc>-mono-white.svg.

Each flag color becomes a shade of the icon color - the darkest solid,
lighter ones fainter, near-white transparent - through an SVG mask (so
overlapping shapes keep working), inside an outline showing the flag's edge.
Shades come from levels.json (see flag_levels.py): per flag, [luminance,
opacity] points for its main colors; other colors are interpolated between.

Normally run through generate_flags.sh. Reads levels.json and the flag-cache/
download cache from the current directory.

usage: make_mono_flags.py OUT_DIR CC [CC ...]
"""
import re, sys, urllib.request
import xml.etree.ElementTree as ET

SRC = "https://cdn.jsdelivr.net/gh/lipis/flag-icons@7/flags/4x3/{}.svg"
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")

# Fallback for a flag missing from levels.json: dark solid, white clear.
DEFAULT_LEVELS = [[0.0, 1.0], [0.8, 0.0]]
levels = DEFAULT_LEVELS
# Shades are raised to this power: >1 dims the in-between shades while
# keeping solid parts solid. The white (dark mode) icons use more, since
# light shades on a dark background otherwise blur into the solid parts.
GAMMA = {"mono": 1.0, "mono-white": 1.8}
gamma = 1.0
NAMED = {"black": "#000", "white": "#fff", "red": "#f00", "blue": "#00f", "green": "#008000",
         "yellow": "#ff0", "gold": "#ffd700", "orange": "#ffa500", "navy": "#000080",
         "silver": "#c0c0c0", "gray": "#808080", "grey": "#808080", "maroon": "#800000",
         "purple": "#800080", "teal": "#008080", "lime": "#0f0", "aqua": "#0ff", "cyan": "#0ff",
         "magenta": "#f0f", "fuchsia": "#f0f", "olive": "#808000", "brown": "#a52a2a"}
unknown = set()


def luminance(color):
    c = NAMED.get(color.lower(), color.lower())
    m = re.fullmatch(r"#([0-9a-f]{3}|[0-9a-f]{6})", c)
    if not m:
        m2 = re.fullmatch(r"rgb\((\d+),\s*(\d+),\s*(\d+)\)", c)
        if not m2:
            return None
        r, g, b = (int(x) / 255 for x in m2.groups())
    else:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    lin = lambda v: v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def shade(lum):
    """Opacity for a color of this luminance, interpolated over `levels`."""
    return interpolate(lum) ** gamma


def interpolate(lum):
    if lum <= levels[0][0]:
        return levels[0][1]
    for (l0, a0), (l1, a1) in zip(levels, levels[1:]):
        if lum <= l1:
            return a0 + (a1 - a0) * (lum - l0) / (l1 - l0)
    return levels[-1][1]


def mask_paint(color):
    """Opaque gray for the mask - opaque so a lighter shape drawn over a
    darker one replaces it (a white cross on a red field). librsvg reads a
    mask gray's sRGB value as coverage: #808080 shows the icon at 50%."""
    v = color.strip()
    if v in ("none", "transparent", "inherit", "currentColor") or v.startswith("url("):
        return v
    lum = luminance(v)
    if lum is None:
        unknown.add(v)
        return "#fff"
    return "#%02x%02x%02x" % ((round(shade(lum) * 255),) * 3)


def recolor(el):
    for attr in ("fill", "stroke", "stop-color"):
        if attr in el.attrib:
            el.set(attr, mask_paint(el.get(attr)))
    if "style" in el.attrib:
        def sub(m):
            return f"{m.group(1)}:{mask_paint(m.group(2))}"
        el.set("style", re.sub(r"(fill|stroke|stop-color)\s*:\s*([^;]+)", sub, el.get("style")))
    for child in el:
        recolor(child)


def fetch(cc, cache_dir="flag-cache"):
    """The flag's source SVG, downloaded once (with retries) into cache_dir."""
    import os, time
    os.makedirs(cache_dir, exist_ok=True)
    path = f"{cache_dir}/{cc}.svg"
    if not os.path.exists(path):
        for attempt in range(4):
            try:
                data = urllib.request.urlopen(SRC.format(cc), timeout=30).read()
                break
            except OSError:
                if attempt == 3:
                    raise
                time.sleep(2 * (attempt + 1))
        with open(path, "wb") as f:
            f.write(data)
    with open(path, "rb") as f:
        return f.read()


def build(cc, color):
    flag = ET.fromstring(fetch(cc))
    vb = [float(x) for x in flag.get("viewBox", "0 0 640 480").split()]
    # Flag area: full icon width like the other sidebar icons, 4:3, centered.
    # Inset by half the 1px outline so the stroke lands on the icon edge.
    x, w = 0.5, 23
    h = w * 3 / 4
    y = (24 - h) / 2
    sx, sy = w / vb[2], h / vb[3]

    svg = ET.Element(f"{{{SVG}}}svg", {"width": "24", "height": "24", "viewBox": "0 0 24 24", "version": "1.1"})
    defs = ET.SubElement(svg, f"{{{SVG}}}defs")
    clip = ET.SubElement(defs, f"{{{SVG}}}clipPath", {"id": "paperboy-flag-clip"})
    ET.SubElement(clip, f"{{{SVG}}}rect", {"x": str(x), "y": str(y), "width": str(w), "height": str(h), "rx": "1.5"})
    mask = ET.SubElement(defs, f"{{{SVG}}}mask", {"id": "paperboy-flag-mask", "maskUnits": "userSpaceOnUse",
                                                   "x": "0", "y": "0", "width": "24", "height": "24"})
    # Unset fills default to black in the flag (darkest, so solid): white here.
    g = ET.SubElement(mask, f"{{{SVG}}}g", {"fill": "#fff",
                                             "transform": f"translate({x - vb[0] * sx} {y - vb[1] * sy}) scale({sx} {sy})"})
    for child in list(flag):
        recolor(child)
        g.append(child)

    ET.SubElement(svg, f"{{{SVG}}}rect", {"x": str(x), "y": str(y), "width": str(w), "height": str(h),
                                           "fill": color, "mask": "url(#paperboy-flag-mask)",
                                           "clip-path": "url(#paperboy-flag-clip)"})
    ET.SubElement(svg, f"{{{SVG}}}rect", {"x": str(x), "y": str(y), "width": str(w), "height": str(h), "rx": "1.5",
                                           "fill": "none", "stroke": color, "stroke-width": "1"})
    return ET.tostring(svg, encoding="unicode")


def main():
    import json, os
    global levels, gamma
    out_dir, codes = sys.argv[1], [c.lower() for c in sys.argv[2:]]
    all_levels = json.load(open("levels.json")) if os.path.exists("levels.json") else {}
    for cc in codes:
        levels = all_levels.get(cc, DEFAULT_LEVELS)
        for suffix, color in (("mono", "#000000"), ("mono-white", "#ffffff")):
            gamma = GAMMA[suffix]
            body = build(cc, color)  # build fully before touching the output file
            with open(f"{out_dir}/flag-{cc}-{suffix}.svg", "w") as f:
                f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
                f.write("<!-- Flag from lipis/flag-icons (MIT), in shades of one color for Paperboy -->\n")
                f.write(body)
                f.write("\n")
        print("ok", cc)
    if unknown:
        print("unrecognized colors (drawn solid):", sorted(unknown))


if __name__ == "__main__":
    main()
