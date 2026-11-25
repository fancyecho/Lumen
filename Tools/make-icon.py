#!/usr/bin/env python3
"""Draws Lumen's app icon and menu bar glyphs. Run from anywhere: python3 Tools/make-icon.py

Writes
  Lumen/Resources/AppIcon.icon                      Icon Composer document; actool compiles it at build
                                                    time and the system adds Liquid Glass, dark, clear
                                                    and tinted appearances itself
  Lumen/Resources/Assets.xcassets/MenuBarIcon*      template glyphs for the menu bar (idle / playing)
  build/icon-preview/*.png                          renders of every appearance, when Xcode's ictool exists

The motif: the icon is itself a wallpaper, a sun rising behind lavender dunes at dusk, edge to edge.
The dunes are separate Liquid Glass layers so each crest catches the system's specular light; the sky
behind them stays flat so the glass reads against it.
"""
import json
import os
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Lumen/Resources/AppIcon.icon")
CATALOG = os.path.join(ROOT, "Lumen/Resources/Assets.xcassets")
PREVIEW = os.path.join(ROOT, "build/icon-preview")
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"


def num(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


# ---------------------------------------------------------------- app icon (1024 canvas)

def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}</defs>{body}</svg>')


def H(t): return 1024 * t   # fraction of the canvas to points


def linear(gid, y0, y1, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{gid}" x1="0" y1="{num(y0)}" x2="0" y2="{num(y1)}" gradientUnits="userSpaceOnUse">{s}</linearGradient>'


def dune(crest, stops):
    """A dune across the whole canvas; `crest` are five heights (fractions) along its top edge.
    It overshoots the canvas so the icon mask, not the path, makes the edge."""
    a, b, c, d, e = crest
    path = (f'M{num(H(-0.05))} {num(H(a))} C {num(H(0.22))} {num(H(b))}, {num(H(0.48))} {num(H(c))}, {num(H(0.7))} {num(H(d))} '
            f'S {num(H(0.98))} {num(H(e))}, {num(H(1.05))} {num(H(e - 0.06))} '
            f'L{num(H(1.05))} {num(H(1.05))} L{num(H(-0.05))} {num(H(1.05))} Z')
    return svg(f'<path d="{path}" fill="url(#g)"/>', linear("g", H(b), H(1.0), stops))


def sky(sun_y=0.60, sun_r=0.08):
    """Muted indigo that warms only near the horizon, with a soft glow around the sun."""
    sx, sy, r = H(0.5), H(sun_y), H(sun_r)
    defs = (linear("sky", 0, H(0.82), [(0, "#1A1638"), (0.5, "#4A408A"), (0.78, "#B286B0"), (1, "#E6B4A6")])
            + f'<radialGradient id="halo" cx="{num(sx)}" cy="{num(sy)}" r="{num(H(0.5))}" gradientUnits="userSpaceOnUse">'
              '<stop offset="0" stop-color="#FFE3D3" stop-opacity="0.9"/><stop offset="0.22" stop-color="#F2B6C6" stop-opacity="0.48"/>'
              '<stop offset="1" stop-color="#8E85D6" stop-opacity="0"/></radialGradient>'
            + f'<radialGradient id="sun" cx="{num(sx)}" cy="{num(sy - H(0.03))}" r="{num(r * 1.05)}" gradientUnits="userSpaceOnUse">'
              '<stop offset="0" stop-color="#FFFCF8"/><stop offset="0.7" stop-color="#FFEADD"/><stop offset="1" stop-color="#FFD5C4"/></radialGradient>')
    body = ('<rect width="1024" height="1024" fill="url(#sky)"/><rect width="1024" height="1024" fill="url(#halo)"/>'
            f'<circle cx="{num(sx)}" cy="{num(sy)}" r="{num(r)}" fill="url(#sun)"/>')
    return svg(body, defs)


ASSETS = {
    "dune-near.svg": dune((0.94, 0.84, 0.86, 0.93, 0.92), [(0, "#3F3487"), (1, "#1F1A4A")]),
    "dune-mid.svg": dune((0.80, 0.70, 0.73, 0.80, 0.83), [(0, "#7466C4"), (1, "#41378C")]),
    "dune-far.svg": dune((0.66, 0.55, 0.57, 0.645, 0.70), [(0, "#B9ADF0"), (1, "#7C6FC9")]),
    "sky.svg": sky(),
}


def p3(r, g, b):
    return f"display-p3:{r:.3f},{g:.3f},{b:.3f},1.000"


DOCUMENT = {
    # The sky layer covers the fill; it only shows if a layer fails to load.
    "fill": {"linear-gradient": [p3(0.102, 0.086, 0.220), p3(0.122, 0.102, 0.290)]},
    "groups": [
        {
            "layers": [  # first layer is frontmost
                {"glass": True, "image-name": "dune-near.svg", "name": "dune-near"},
                {"glass": True, "image-name": "dune-mid.svg", "name": "dune-mid"},
                {"glass": True, "image-name": "dune-far.svg", "name": "dune-far"},
                {"glass": False, "image-name": "sky.svg", "name": "sky"},
            ],
            "lighting": "individual",
            "shadow": {"kind": "layer-color", "opacity": 0.45},
            "specular": True,
            "translucency": {"enabled": False, "value": 0},
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}


# ---------------------------------------------------------------- menu bar glyphs (18 pt canvas)
#
# The app icon reduced to a mark: the sun as a disc, cut by two dune-shaped gaps. While anything plays
# the whole disc is lit; when idle only the dunes stay solid under an open ring, like the sun gone out.
# No rays, so it does not read as a weather symbol.

DISC = (9.0, 9.0, 7.0)   # centre x, centre y, radius
RING = 1.5               # idle outline, matching the weight of the system's menu bar symbols
GAP = 1.2                # width of each dune cut


class Wave:
    """A dune edge across the canvas: two cubic segments joined smoothly at (xm, ymid)."""

    def __init__(self, yl, ycrest, ymid, ytrough, yr, xc, xm, xt):
        self.p0, self.c1, self.c2 = (-1, yl), (xc - 3.0, ycrest - (yl - ycrest) * 0.25), (xc + 1.6, ycrest)
        self.p1 = (xm, ymid)
        self.c3, self.c4, self.p2 = (2 * xm - self.c2[0], 2 * ymid - self.c2[1]), (xt + 2.4, ytrough), (19, yr)

    @staticmethod
    def _pt(p, dy):
        return f"{num(p[0])} {num(p[1] + dy)}"

    def forward(self, dy=0):
        q = self._pt
        return f"M{q(self.p0, dy)} C{q(self.c1, dy)} {q(self.c2, dy)} {q(self.p1, dy)} C{q(self.c3, dy)} {q(self.c4, dy)} {q(self.p2, dy)}"

    def backward(self, dy=0):
        q = self._pt
        return f"L{q(self.p2, dy)} C{q(self.c4, dy)} {q(self.c3, dy)} {q(self.p1, dy)} C{q(self.c2, dy)} {q(self.c1, dy)} {q(self.p0, dy)}"


# Far and near dune edges; the crests sit at different x like the icon's dunes.
DUNES = [Wave(10.4, 8.8, 9.9, 11.0, 9.6, xc=4.2, xm=9.2, xt=13.8),
         Wave(13.4, 12.3, 13.0, 13.9, 12.7, xc=5.0, xm=10.0, xt=14.6)]


def bands():
    """Sky, far dune and near dune as closed shapes, separated by the dune cuts (to be clipped to the disc)."""
    g = GAP / 2
    shapes = ["M-1 -1 L19 -1 " + DUNES[0].backward(-g) + " Z"]
    for upper, lower in zip(DUNES, DUNES[1:]):
        shapes.append(upper.forward(g) + " " + lower.backward(-g) + " Z")
    shapes.append(DUNES[-1].forward(g) + " L19 19 L-1 19 Z")
    return shapes


def glyph(body, defs):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><defs>{defs}</defs>{body}</svg>'


def menu_glyph(lit):
    cx, cy, r = DISC
    clip = f'<clipPath id="disc"><circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r)}"/></clipPath>'
    shapes = bands() if lit else bands()[1:]
    body = '<g clip-path="url(#disc)">' + "".join(f'<path d="{d}"/>' for d in shapes) + "</g>"
    if not lit:
        body = (f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r - RING / 2)}" fill="none" stroke="#000" '
                f'stroke-width="{num(RING)}"/>') + body
    return glyph(body, clip)


def write_imageset(name, svg_text):
    folder = os.path.join(CATALOG, f"{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"{name}.svg"), "w") as f:
        f.write(svg_text)
    contents = {
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


# ---------------------------------------------------------------- output

def main():
    if os.path.exists(ICON):
        shutil.rmtree(ICON)
    os.makedirs(os.path.join(ICON, "Assets"))
    for name, text in ASSETS.items():
        with open(os.path.join(ICON, "Assets", name), "w") as f:
            f.write(text)
    with open(os.path.join(ICON, "icon.json"), "w") as f:
        json.dump(DOCUMENT, f, indent=2)
        f.write("\n")
    write_imageset("MenuBarIcon", menu_glyph(lit=False))
    write_imageset("MenuBarIconPlaying", menu_glyph(lit=True))
    print(f"wrote {os.path.relpath(ICON, ROOT)} and the MenuBarIcon image sets")

    if os.path.exists(ICTOOL):
        os.makedirs(PREVIEW, exist_ok=True)
        for rendition in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]:
            out = os.path.join(PREVIEW, f"AppIcon-{rendition}.png")
            subprocess.run([ICTOOL, ICON, "--export-image", "--output-file", out, "--platform", "macOS",
                            "--rendition", rendition, "--width", "1024", "--height", "1024", "--scale", "1"],
                           check=True, stdout=subprocess.DEVNULL)
        print(f"previews in {os.path.relpath(PREVIEW, ROOT)}")


if __name__ == "__main__":
    main()
