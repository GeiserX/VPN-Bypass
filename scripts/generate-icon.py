#!/usr/bin/env python3
"""Regenerate the app icon, in-app logo, and README banner logo from the
community-suggested source art.

Pipeline:
  assets/AppIcon-source-tetonne.png  (flattened JPEG-style art, baked-in
                                       checkerboard "transparency")
    -> detect the colored squircle, crop it, recolor the light fringe to navy,
       apply a macOS continuous-corner (superellipse) alpha mask
    -> master_1024.png, AppIcon.iconset/ (16->1024), VPNBypass.png (in-app logo),
       banner_logo.png + banner_logo.b64.txt

The base64 in banner_logo.b64.txt is pasted into the <image> data URI in
docs/images/banner.svg. From the generated AppIcon.iconset, build the icns with:
    iconutil -c icns <out>/AppIcon.iconset -o assets/AppIcon.icns

Usage:
    python scripts/generate-icon.py [source_image] [output_dir]
Defaults: source = assets/AppIcon-source-tetonne.png, output = build/icon-gen
(both resolved relative to the repo root).
"""

import base64
import os
import sys

import numpy as np
from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "assets", "AppIcon-source-tetonne.png")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO_ROOT, "build", "icon-gen")

if not os.path.isfile(SRC):
    sys.exit(f"Error: source image not found: {SRC}\n"
             f"Usage: python scripts/generate-icon.py [source_image] [output_dir]")
os.makedirs(OUT, exist_ok=True)

# Source is a flattened JPEG: the "transparent" checkerboard is baked into the
# pixels (no real alpha). Detect the colored squircle, crop it, recolor the
# light checkerboard fringe to the squircle's own navy so masking never exposes
# white, then apply a macOS continuous-corner (superellipse) alpha mask.
NAVY = (24, 42, 70)  # sampled dominant squircle fill

im = Image.open(SRC).convert("RGB")
a = np.asarray(im).astype(int)
r, g, b = a[..., 0], a[..., 1], a[..., 2]
mx = np.maximum(np.maximum(r, g), b)
mn = np.minimum(np.minimum(r, g), b)
sat = mx - mn
bright = mx

core = (sat > 28) | ((bright < 140) & (b >= r))
ys, xs = np.where(core)
if xs.size == 0:
    sys.exit("Error: could not detect a colored squircle in the source image "
             "(no pixels matched the saturation/brightness heuristic).")
x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
side = max(x1 - x0, y1 - y0)
half = side / 2.0 + 4
L = int(round(cx - half))
T = int(round(cy - half))
S = int(round(2 * half))

crop = im.crop((L, T, L + S, T + S)).resize((1024, 1024), Image.LANCZOS)
c = np.asarray(crop).astype(np.uint8).copy()
cr, cg, cb = c[..., 0].astype(int), c[..., 1].astype(int), c[..., 2].astype(int)
cmx = np.maximum(np.maximum(cr, cg), cb)
cmn = np.minimum(np.minimum(cr, cg), cb)
# checkerboard / light fringe: bright and low-saturation gray
fringe = (cmx > 175) & ((cmx - cmn) < 30)
c[fringe] = NAVY

N = 1024
yy, xx = np.mgrid[0:N, 0:N].astype(float)
xn = (xx - (N - 1) / 2) / ((N - 1) / 2)
yn = (yy - (N - 1) / 2) / ((N - 1) / 2)
n = 5.0
d = np.abs(xn) ** n + np.abs(yn) ** n
# threshold < 1.0 so the anti-aliased edge sits inside solid navy (no light rim)
thresh = 0.965
edge = 0.05
alpha = np.clip((thresh - d) / edge + 0.5, 0, 1)
alpha = (alpha * 255).astype(np.uint8)

# pre-fill RGB behind transparent pixels with navy so no light halo bleeds
fill = np.empty_like(c)
fill[:] = NAVY
a_f = (alpha.astype(float) / 255.0)[..., None]
blended = (c.astype(float) * a_f + fill.astype(float) * (1 - a_f)).astype(np.uint8)

rgba = np.dstack([blended, alpha])
master = Image.fromarray(rgba, "RGBA")
master.save(f"{OUT}/master_1024.png")
print("crop box", (L, T, S), "-> 1024 squircle saved")

iconset = f"{OUT}/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)
sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
         (512, "512x512"), (1024, "512x512@2x")]
for px, name in sizes:
    master.resize((px, px), Image.LANCZOS).save(f"{iconset}/icon_{name}.png")
print("iconset written")

# in-app logo (shown .fit in square frames)
master.resize((512, 512), Image.LANCZOS).save(f"{OUT}/VPNBypass.png")

# banner logo + base64 (paste into docs/images/banner.svg)
small = master.resize((160, 160), Image.LANCZOS)
small.save(f"{OUT}/banner_logo.png")
with open(f"{OUT}/banner_logo.png", "rb") as img:
    banner_b64 = base64.b64encode(img.read()).decode()
with open(f"{OUT}/banner_logo.b64.txt", "w") as f:
    f.write(banner_b64)
print("logo + banner assets written")
