#!/usr/bin/env python3
"""Builds the two App Store creative assets from the icon and the screenshots.

    Design/app-store/make.py            # after scripts/screenshots.sh

Writes out/header-3840x1646.png and out/search-3840x2560.png beside this file.
Needs rsvg-convert and Pillow. Sizes and safe areas are Apple's "creative
assets specifications"; pass --guides to draw the safe area on each image.
"""
import io
import pathlib
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
ICON = REPO / "Design" / "AppIcon.svg"
SHOTS = REPO / "build" / "screenshots" / "iPhone-17-Pro-Max"
OUT = HERE / "out"

GROUND = "#e0b81f"  # Yellow Ocher, the icon's ground
ORANGE = "#ff8c00"  # Yellow Orange, the icon's halftone

# (canvas size, art safe area as x, y, w, h)
HEADER = ((3840, 1646), (1097, 493, 1646, 661))
SEARCH = ((3840, 2560), (836, 765, 2168, 1030))


def rsvg(svg: str, width: int, height: int) -> Image.Image:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(width), "-h", str(height)],
        input=svg.encode(), capture_output=True, check=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def background(size, centre) -> Image.Image:
    """The icon's ground, with its halftone sun carried out to the edges."""
    w, h = size
    cx, cy = centre
    reach = max(cx, w - cx) * 1.05
    rings = []
    # Dots shrink with distance, so the sun fades into the ground.
    for i, (r0, r1, dot) in enumerate([
        (0.00, 0.30, 9.0), (0.30, 0.48, 7.0), (0.48, 0.66, 5.2),
        (0.66, 0.84, 3.6), (0.84, 1.00, 2.2),
    ]):
        mid, width = (r0 + r1) / 2 * reach, (r1 - r0) * reach
        rings.append(
            f'<pattern id="p{i}" width="30" height="30" patternUnits="userSpaceOnUse" '
            f'patternTransform="rotate(30)"><circle cx="15" cy="15" r="{dot}" fill="{ORANGE}"/></pattern>'
            f'<circle cx="{cx}" cy="{cy}" r="{mid}" fill="none" stroke="url(#p{i})" stroke-width="{width + 1}"/>'
        )
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
        f'<rect width="{w}" height="{h}" fill="{GROUND}"/>{"".join(rings)}</svg>'
    )
    return rsvg(svg, w, h)


def icon_art(px: int) -> Image.Image:
    """The icon without its ground rectangle, on transparency."""
    svg = ICON.read_text()
    lines = [l for l in svg.splitlines() if '<rect id="ground"' not in l]
    assert len(lines) == len(svg.splitlines()) - 1, "ground rect not found"
    return rsvg("\n".join(lines), px, px)


def phone(shot: pathlib.Path, height: int) -> Image.Image:
    """A screenshot in a plain black bezel, with a soft shadow."""
    screen = Image.open(shot).convert("RGB")
    sw = round(height * screen.width / screen.height)
    screen = screen.resize((sw, height), Image.Resampling.LANCZOS)
    bezel, radius = round(sw * 0.035), round(sw * 0.15)
    w, h = sw + 2 * bezel, height + 2 * bezel
    pad = 120
    out = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))

    shadow = Image.new("L", out.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (pad, pad + 30, pad + w, pad + h + 30), radius + bezel, fill=110)
    out.putalpha(shadow.filter(ImageFilter.GaussianBlur(40)))

    body = Image.new("L", out.size, 0)
    ImageDraw.Draw(body).rounded_rectangle(
        (pad, pad, pad + w, pad + h), radius + bezel, fill=255)
    out.paste((12, 10, 8, 255), mask=body)

    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw, height), radius, fill=255)
    out.paste(screen, (pad + bezel, pad + bezel), mask)
    return out


def place(canvas, layer, centre):
    canvas.alpha_composite(
        layer, (round(centre[0] - layer.width / 2), round(centre[1] - layer.height / 2)))


def finish(canvas, safe, name, guides):
    if guides:
        x, y, w, h = safe
        ImageDraw.Draw(canvas).rectangle((x, y, x + w, y + h), outline="#ff00ff", width=8)
        name += "-guides"
    OUT.mkdir(exist_ok=True)
    path = OUT / f"{name}.png"
    canvas.convert("RGB").save(path, optimize=True)  # no alpha: the store rejects it
    print(path)


def header(guides):
    size, safe = HEADER
    centre = (safe[0] + safe[2] / 2, safe[1] + safe[3] / 2)
    canvas = background(size, centre)
    place(canvas, icon_art(880), (centre[0] - 12, centre[1] + 8))
    finish(canvas, safe, "header-3840x1646", guides)


def search(guides):
    size, safe = SEARCH
    cx, cy = safe[0] + safe[2] / 2, safe[1] + safe[3] / 2
    canvas = background(size, (cx, cy))
    side, mid, step = 1400, 1700, 735
    # The centre phone sits low so the safe area covers status bar to PTT key.
    place(canvas, phone(SHOTS / "1-channels-dark.png", side), (cx - step, cy + 150))
    place(canvas, phone(SHOTS / "2-receiving-dark.png", side), (cx + step, cy + 150))
    place(canvas, phone(SHOTS / "3-transmitting-dark.png", mid), (cx, cy + 240))
    finish(canvas, safe, "search-3840x2560", guides)


if __name__ == "__main__":
    g = "--guides" in sys.argv
    header(g)
    search(g)
