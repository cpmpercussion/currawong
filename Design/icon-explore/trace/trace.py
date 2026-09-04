#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Trace a four-colour icon-explore keeper into an SVG, with a hand-drawn bill and markings.

    ./trace.py                      # rebuilds work/currawong-331.svg from the keeper PNG
    ./trace.py --render             # also renders work/preview-{1024,128}.png
    ./trace.py --install            # writes Design/AppIcon.svg and Design/AppIcon-macOS.svg

Pipeline, all standard tools (brew install imagemagick potrace librsvg):

  1. Remap the PNG to Sanzo Wada no. 222 + black after a light blur, so the
     anti-aliased edges snap to one colour or the other.
  2. One potrace pass per ink. The sun disc is *not* traced: the model drew it
     as speckle, which traces to a 350 KB cloud, so it becomes a real <circle>
     filled with an SVG halftone pattern. Only the rays outside the disc are traced.
  3. The eye and wing patch are holes in the black layer. They get a solid ocher
     fill underneath so the halftone does not show through them.
  4. The model's bill is masked off the black layer and replaced by BILL below:
     a pied currawong's bill is deep, straight along the culmen and hooked only
     at the tip, and no prompt got FLUX Kontext to draw one.

Intermediates land in work/ (git-ignored). Edit BILL or the geometry constants,
rerun, look at the preview.
"""
import argparse, pathlib, re, subprocess

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent / "out/20260904-194400/kontext-clean-singing-black-101-v3-331.png"
OUT = HERE / "work/currawong-331.svg"
WORK = HERE / "work"

OCHER, ORANGE, RUFOUS, BLACK = "#e0b81f", "#ff8c00", "#c05200", "#000000"
SUN = dict(cx=528, cy=508, r=415)          # measured from the dense ring of the model's disc
BILL_MASK = "95,80 250,95 310,135 322,150 302,190 290,224 125,190 95,175"
BILL = {
    # Base edges sit inside the black head so there is no seam.
    "upper-mandible": "M 330 150 L 196 108 Q 186 105 183 116 C 215 128 270 190 300 190 Z",
    "lower-mandible": "M 300 190 L 185 172 L 188 182 Q 235 206 288 222 L 320 218 Z",
}
# Only these two holes in the black silhouette are real: the gap between the legs
# and the branch is enclosed too, and must stay see-through.
HOLE_BOXES = ["330,150 410,225", "460,490 650,590"]
# The pale markings the model left off, drawn in ocher and clipped to the bird:
# a band across the tail tip and the undertail coverts. Oversized on purpose;
# only what falls inside the black silhouette shows.
TAIL_TIP = "830,880 975,860 975,930 830,930"
UNDERTAIL = dict(cx=810, cy=823, rx=45, ry=16, rotate=56)
RIM = 12   # stroke width; half of it shows as a black rim inside the silhouette where a marking meets the edge
RAY_FATTEN = "Disk:1.2"   # hair-line rays vanish at icon size; this widens them ~2 px
POTRACE_T = "translate(0,1024) scale(0.1,-0.1)"


def sh(*args):
    subprocess.run([str(a) for a in args], check=True)


def ink_mask(flat, colour, dest):
    sh("magick", flat, "-fill", "white", "+opaque", colour, "-fill", "black", "-opaque", colour,
       "-threshold", "50%", dest)


def trace(mask, dest, turd):
    sh("potrace", "-s", "-t", str(turd), "-a", "1.0", "-O", "0.3", "--flat", "-o", dest, mask)
    return re.search(r'<path d="([^"]+)"', dest.read_text(), re.S).group(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--render", action="store_true")
    ap.add_argument("--install", action="store_true", help="write the two Design/AppIcon*.svg files")
    a = ap.parse_args()
    WORK.mkdir(exist_ok=True)

    palette = WORK / "palette.png"
    sh("magick", "-size", "1x1", f"xc:{OCHER}", f"xc:{ORANGE}", f"xc:{RUFOUS}", f"xc:{BLACK}", "+append", palette)
    flat = WORK / "flat.png"
    sh("magick", SRC, "-blur", "0x1.2", "-remap", palette, flat)

    black = WORK / "mask-black.pbm"
    ink_mask(flat, BLACK, black)
    rufous = WORK / "mask-rufous.pbm"
    ink_mask(flat, RUFOUS, rufous)
    # The rufous layer picks up a 1-2 px halo where black meets ocher; opening removes it.
    sh("magick", rufous, "-negate", "-morphology", "Open", "Disk:1.5", "-negate", rufous)
    orange = WORK / "mask-orange.pbm"
    ink_mask(flat, ORANGE, orange)
    rays = WORK / "mask-rays.pbm"
    sh("magick", orange, "-fill", "white", "-draw",
       f"circle {SUN['cx']},{SUN['cy']} {SUN['cx']},{SUN['cy'] - SUN['r']}",
       "-negate", "-morphology", "Dilate", RAY_FATTEN, "-negate", rays)
    # Flood the exterior from a corner; whatever stays white is enclosed by black.
    holes = WORK / "mask-holes.pbm"
    keep = sum((["-draw", f"rectangle {b}"] for b in HOLE_BOXES), [])
    sh("magick", black, "-fill", "red", "-draw", "color 0,0 floodfill",
       "-fill", "black", "-opaque", "white", "-fill", "white", "-opaque", "red",
       "(", "+clone", "-fill", "white", "-colorize", "100", "-fill", "black", *keep, ")",
       "-compose", "Lighten", "-composite", "-threshold", "50%", holes)

    d = {
        "rays": trace(rays, WORK / "layer-rays.svg", 40),
        "foliage": trace(rufous, WORK / "layer-rufous.svg", 30),
        "holes": trace(holes, WORK / "layer-holes.svg", 10),
        "bird": trace(black, WORK / "layer-black.svg", 25),
    }
    bill = "\n".join(f'    <path id="{k}" d="{v}"/>' for k, v in BILL.items())
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- Generated by Design/icon-explore/trace/trace.py from {SRC.relative_to(HERE.parent)}
       (text-prompted FLUX schnell -> FLUX Kontext; no photograph anywhere in the chain).
       Palette: Sanzo Wada combination no. 222 plus black. The sun is a real circle with an SVG
       halftone fill rather than the model's speckle, and the bill is hand-drawn (see #bill). -->
  <defs>
    <pattern id="ht" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(30)">
      <circle cx="4.5" cy="4.5" r="2.9" fill="{ORANGE}"/>
    </pattern>
    <pattern id="ht-dense" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(30)">
      <circle cx="4.5" cy="4.5" r="3.9" fill="{ORANGE}"/>
    </pattern>
    <!-- Blanks the traced bill so the hand-drawn one can replace it. -->
    <mask id="no-old-bill">
      <rect width="1024" height="1024" fill="white"/>
      <polygon fill="black" points="{BILL_MASK}"/>
    </mask>
    <clipPath id="bird-clip"><use href="#bird-path" transform="{POTRACE_T}"/></clipPath>
  </defs>
  <rect id="ground" width="1024" height="1024" fill="{OCHER}"/>
  <g id="sun">
    <circle cx="{SUN['cx']}" cy="{SUN['cy']}" r="{SUN['r']}" fill="url(#ht)"/>
    <circle cx="{SUN['cx']}" cy="{SUN['cy']}" r="{SUN['r'] - 30}" fill="none" stroke="url(#ht-dense)" stroke-width="60"/>
  </g>
  <g id="rays" transform="{POTRACE_T}" fill="{ORANGE}"><path d="{d['rays']}"/></g>
  <g id="foliage" transform="{POTRACE_T}" fill="{RUFOUS}"><path d="{d['foliage']}"/></g>
  <g id="wing-patch-and-eye" transform="{POTRACE_T}" fill="{OCHER}"><path d="{d['holes']}"/></g>
  <g mask="url(#no-old-bill)">
    <g id="bird" transform="{POTRACE_T}" fill="{BLACK}"><path id="bird-path" d="{d['bird']}"/></g>
  </g>
  <!-- Pied currawong markings: undertail coverts and the tail-tip band, in ocher for white. -->
  <g id="markings" fill="{OCHER}" clip-path="url(#bird-clip)" mask="url(#no-old-bill)">
    <ellipse cx="{UNDERTAIL['cx']}" cy="{UNDERTAIL['cy']}" rx="{UNDERTAIL['rx']}" ry="{UNDERTAIL['ry']}" transform="rotate({UNDERTAIL['rotate']} {UNDERTAIL['cx']} {UNDERTAIL['cy']})"/>
    <polygon points="{TAIL_TIP}"/>
    <!-- Ocher stands in for white, and the ground is ocher too, so a marking that reaches the
         silhouette edge needs a black rim to stay legible. Black on black elsewhere. -->
    <use href="#bird-path" transform="{POTRACE_T}" fill="none" stroke="{BLACK}" stroke-width="{RIM * 10}"/>
  </g>
  <!-- Hand-drawn pied currawong bill: deep at the base, straight culmen, small downward hook at
       the tip, open in song. -->
  <g id="bill" fill="{BLACK}">
{bill}
  </g>
</svg>
'''
    OUT.write_text(svg)
    print(f"{OUT.relative_to(HERE.parent)}  {len(svg)//1024} KB")
    if a.install:
        design = HERE.parent.parent
        (design / "AppIcon.svg").write_text(svg)
        inner = svg.split(">", 1)[1].rsplit("</svg>", 1)[0]
        # The pre-Tahoe macOS treatment: an 824x824 rounded rectangle (r=185) centred
        # on a transparent 1024 canvas, wrapping the same artwork.
        (design / "AppIcon-macOS.svg").write_text(f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <clipPath id="squircle">
      <rect x="100" y="100" width="824" height="824" rx="185" ry="185"/>
    </clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <g transform="translate(100,100) scale(0.8046875)">{inner}</g>
  </g>
</svg>
''')
        print("installed Design/AppIcon.svg and Design/AppIcon-macOS.svg")
    if a.render:
        for px in (1024, 128):
            sh("rsvg-convert", "-w", px, "-h", px, OUT, "-o", WORK / f"preview-{px}.png")
        print(f"previews in {WORK.relative_to(HERE.parent)}/")


if __name__ == "__main__":
    main()
