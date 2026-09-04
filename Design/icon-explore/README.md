# Icon exploration

A prompt-engineering loop for a screen-print style Currawong icon, run against
[Replicate](https://replicate.com). Nothing here ships; a keeper gets traced or
cleaned up into `Design/AppIcon.svg` and goes through
`scripts/generate-app-icon.sh` as before.

```sh
export REPLICATE_API_TOKEN=r8_...   # or ~/.config/replicate/api_token
./explore.py --dry-run             # read the resolved prompts
./explore.py -n 2                  # every variant, two seeds each
./explore.py -v bust-orange -n 4 --seed 7
./explore.py --model black-forest-labs/flux-1.1-pro -v bust-orange -n 2   # once a prompt is close
./explore.py --remap wada222 out/<run>/bust-orange-*.png   # snap to exact Wada hexes
open out/<run>/index.html
```

- `prompts.json` is the thing you edit. One `style` block, one `subject`
  block, and variants that change one idea each. `{palette}` is filled from
  the named scheme in `palette.json`.
- `palette.json` holds the Sanzo Wada colours. Wada's combination no. 222
  (Yellow Ocher, Yellow Orange, Orange Rufous) is exactly the current icon's
  three fills; the `wada222` scheme is that plus black.
- Models describe colours approximately, so `--remap` quantises a finished
  image to a scheme's exact hexes with ImageMagick. Floyd-Steinberg dither
  keeps the halftone grain.
- `reference-pied-currawong-jjharrison.jpg` is JJ Harrison's photograph from
  Wikimedia Commons, **CC BY-SA 4.0**. It is used only as an image-to-image
  reference by the `kontext-photo` variant, and is not committed — fetch it from
  Wikimedia Commons if you want to rerun that variant. Anything shipped that is visibly
  derived from it would carry the share-alike terms, so treat that variant as
  a pose study, not a source for the final icon.
- `out/` is git-ignored.

## Tracing a keeper

`trace/trace.py --install` turns the keeper into `Design/AppIcon.svg` and its macOS
wrapper: a potrace
pass per ink, the sun as a real circle with an SVG halftone fill, and a
hand-drawn bill. The bill was the one thing no prompt could fix — Kontext kept
the source's slim blackbird bill through three variants and a bill-only edit —
and it is a two-path shape once the image is vectors, so it is drawn in
`BILL` at the top of the script. The keeper, `kontext-clean-singing-black-101-v3-331`,
descends from a text-only image (`singing-orange-101`), so nothing in its
chain touches the CC BY-SA photograph.

```sh
brew install potrace          # ImageMagick and librsvg are already needed by scripts/
trace/trace.py --render       # rebuilds the SVG; previews in trace/work/
```

The ocher tail tip and undertail coverts the model never drew are added as
shapes clipped to the silhouette, with a black inner rim so ocher-on-ocher
stays legible at the edge; the rays are widened a couple of pixels for icon
size. All of it is constants at the top of the script.

The default model is FLUX schnell, about a cent and a couple of seconds per
image, so a 20-image run is pocket change. Move a promising prompt to
`--model black-forest-labs/flux-1.1-pro` for the finer halftone detail.
