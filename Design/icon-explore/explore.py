#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prompt-engineering loop for the Currawong icon, against Replicate.

    export REPLICATE_API_TOKEN=r8_...        # or put it in ~/.config/replicate/api_token
    ./explore.py                              # every variant in prompts.json, 1 image each
    ./explore.py -v bust-orange -n 4          # one variant, four seeds
    ./explore.py --model black-forest-labs/flux-1.1-pro -v bust-orange -n 2
    ./explore.py --remap wada222 out/<run>/*.png  # quantise finished images to a scheme

Each run writes out/<timestamp>/ with the PNGs, a manifest.json (exact prompt,
model, seed, prediction id) and index.html, a contact sheet with the prompt
under every image. Open the sheet, edit prompts.json, run again.

Standard library only; talks to https://api.replicate.com/v1 directly.
"""
import argparse, base64, json, mimetypes, os, pathlib, subprocess, sys, time, urllib.request, urllib.error

HERE = pathlib.Path(__file__).resolve().parent
API = "https://api.replicate.com/v1"

# Text-to-image models take {prompt, aspect_ratio, output_format, seed}; schnell
# is cheap and fast (~1c, ~2s), so iterate there and switch --model to
# black-forest-labs/flux-1.1-pro or flux-dev once a prompt is close.
# Image-to-image (Kontext) additionally takes input_image, and is picked
# automatically for any variant that names an "image".
TEXT_MODEL = "black-forest-labs/flux-schnell"
IMAGE_MODEL = "black-forest-labs/flux-kontext-pro"


def token():
    t = os.environ.get("REPLICATE_API_TOKEN")
    if not t:
        p = pathlib.Path.home() / ".config/replicate/api_token"
        if p.exists():
            t = p.read_text().strip()
    if not t:
        sys.exit("no token: export REPLICATE_API_TOKEN or write ~/.config/replicate/api_token")
    return t


def api(method, path, body=None, tok=None, wait=False):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Content-Type", "application/json")
    if wait:
        req.add_header("Prefer", "wait=60")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=90) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode()[:800]}")


def predict(model, inp, tok):
    """Create a prediction on a model's latest version and block until it settles."""
    pred = api("POST", f"/models/{model}/predictions", {"input": inp}, tok, wait=True)
    while pred["status"] not in ("succeeded", "failed", "canceled"):
        time.sleep(2)
        pred = api("GET", f"/predictions/{pred['id']}", tok=tok)
    if pred["status"] != "succeeded":
        print(f"  {pred['status']}: {pred.get('error')}", file=sys.stderr)
    return pred


def data_uri(path):
    mime = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


def palette_text(pal, scheme):
    names = pal["schemes"][scheme]
    by = {c["name"]: c for c in pal["colors"]}
    parts = []
    for n in names:
        c = by.get(n)
        parts.append(f"{c['name'].lower()} ({c['hex']})" if c else n)
    return ", ".join(parts)


def remap(scheme, files, pal):
    """Quantise images to a scheme's colours with ImageMagick. This is the cheap
    way to make a model's approximate palette exactly Sanzo Wada; Floyd-Steinberg
    keeps the halftone feel, --no-dither gives flat spot colour."""
    names = pal["schemes"][scheme]
    by = {c["name"]: c["hex"] for c in pal["colors"]}
    hexes = [by.get(n, n.split()[-1]) for n in names]
    swatch = HERE / "out" / f"palette-{scheme}.png"
    swatch.parent.mkdir(exist_ok=True)
    cmd = ["magick", "-size", "1x1"] + sum([["xc:" + h] for h in hexes], []) + ["+append", str(swatch)]
    subprocess.run(cmd, check=True)
    for f in files:
        f = pathlib.Path(f)
        out = f.with_name(f.stem + f"-remap-{scheme}.png")
        subprocess.run(["magick", str(f), "-dither", "FloydSteinberg", "-remap", str(swatch), str(out)], check=True)
        print(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-v", "--variant", action="append", help="variant id(s) from prompts.json; default all")
    ap.add_argument("-n", "--count", type=int, default=1, help="images per variant (distinct seeds)")
    ap.add_argument("--model", default=TEXT_MODEL, help=f"text-to-image model (default {TEXT_MODEL})")
    ap.add_argument("--image-model", default=IMAGE_MODEL, help=f"image-to-image model (default {IMAGE_MODEL})")
    ap.add_argument("--aspect", default="1:1")
    ap.add_argument("--seed", type=int, help="first seed; later images use seed+1, seed+2...")
    ap.add_argument("--dry-run", action="store_true", help="print the resolved prompts and stop")
    ap.add_argument("--remap", metavar="SCHEME", help="skip generation; quantise FILES to this scheme")
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()

    pal = json.loads((HERE / "palette.json").read_text())
    if a.remap:
        return remap(a.remap, a.files, pal)

    cfg = json.loads((HERE / "prompts.json").read_text())
    variants = [v for v in cfg["variants"] if not a.variant or v["id"] in a.variant]
    if not variants:
        sys.exit(f"no such variant; have {[v['id'] for v in cfg['variants']]}")

    resolved = []
    for v in variants:
        prompt = v["prompt"].format(style=cfg["style"], subject=cfg["subject"], palette=palette_text(pal, v["scheme"]))
        resolved.append((v, " ".join(prompt.split())))
    if a.dry_run:
        for v, p in resolved:
            print(f"== {v['id']} [{v.get('image') and a.image_model or a.model}]\n{p}\n")
        return

    tok = token()
    run = HERE / "out" / time.strftime("%Y%m%d-%H%M%S")
    run.mkdir(parents=True)
    manifest = []
    seed0 = a.seed if a.seed is not None else int(time.time()) % 100000
    for v, prompt in resolved:
        for i in range(a.count):
            seed = seed0 + i
            model = a.image_model if v.get("image") else a.model
            inp = {"prompt": prompt, "aspect_ratio": a.aspect, "output_format": "png", "seed": seed}
            if v.get("image"):
                inp["input_image"] = data_uri(HERE / v["image"])
            print(f"{v['id']} seed={seed} {model} ...", flush=True)
            pred = predict(model, inp, tok)
            url = pred.get("output")
            if isinstance(url, list):
                url = url[0]
            entry = {"id": v["id"], "seed": seed, "model": model, "prompt": prompt,
                     "prediction": pred["id"], "status": pred["status"], "file": None}
            if url:
                dest = run / f"{v['id']}-{seed}.png"
                urllib.request.urlretrieve(url, dest)
                entry["file"] = dest.name
                print(f"  -> {dest.relative_to(HERE)}")
            manifest.append(entry)
            # Written after every image so a stall or ^C never loses a run.
            (run / "manifest.json").write_text(json.dumps({"negative_hint": cfg.get("negative"), "images": manifest}, indent=2))
            write_sheet(run, manifest)
    print(f"\nopen {run / 'index.html'}")


def write_sheet(run, manifest):
    cards = []
    for m in manifest:
        img = f'<img src="{m["file"]}">' if m["file"] else f'<div class="fail">{m["status"]}</div>'
        cards.append(f'<figure>{img}<figcaption><b>{m["id"]}</b> · seed {m["seed"]} · {m["model"]}'
                     f'<p>{m["prompt"]}</p></figcaption></figure>')
    (run / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>icon explore</title><style>"
        "body{background:#111;color:#ddd;font:14px system-ui;margin:2rem}"
        "main{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:1.5rem}"
        "figure{margin:0}img{width:100%;border-radius:18%}.fail{aspect-ratio:1;background:#400;display:grid;place-items:center}"
        "p{color:#999;font-size:12px}</style><main>" + "".join(cards) + "</main>")


if __name__ == "__main__":
    main()
