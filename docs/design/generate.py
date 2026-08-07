#!/usr/bin/env python3
"""Generate every identity asset for each candidate direction from one source of truth.

The point of generating rather than hand-drawing: a direction is only worth choosing if the
SAME mark survives every surface — 18px template glyph, 1024px app icon, wordmark, banner.
Drawing each surface by hand lets them drift; deriving them all from one path set cannot.
"""
import os
import subprocess

OUT = os.path.join(os.path.dirname(__file__), "proposals")
os.makedirs(OUT, exist_ok=True)

# --- The four directions -----------------------------------------------------------------
# `glyph` is drawn on a 24x24 grid and must read as a silhouette (menu bar icons are
# template images: only the alpha channel survives, colour is discarded by macOS).
DIRECTIONS = {
    "lanes": {
        "name": "Lanes",
        "idea": "Two routes leave together; one passes straight through, the other stops at the wall.",
        "ink": "#2563EB", "ink2": "#1E40AF", "bg1": "#0B1220", "bg2": "#152A4E", "accent": "#38BDF8",
        "bbox": (1.2, 3.4, 19.9, 21.7),
        "solid": '''
  <g fill="none" stroke="{S}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2.5 7.5 H17"/><path d="M14.4 4.7 L17.6 7.5 L14.4 10.3"/><path d="M2.5 16.5 H13"/>
  </g>
  <rect x="15.6" y="12.6" width="2.8" height="7.8" rx="1.2" fill="{S}"/>''',
        "outline": '''
  <g fill="none" stroke="{S}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2.5 7.5 H17"/><path d="M14.4 4.7 L17.6 7.5 L14.4 10.3"/><path d="M2.5 16.5 H13"/>
    <rect x="15.8" y="12.8" width="2.4" height="7.4" rx="1.1"/>
  </g>''',
    },
    "tunnel": {
        "name": "Tunnel",
        "idea": "The VPN is the tunnel. Your listed traffic goes over the top instead of through it.",
        "ink": "#4F46E5", "ink2": "#3730A3", "bg1": "#0E0B24", "bg2": "#2B2470", "accent": "#A78BFA",
        "bbox": (0.7, 3.0, 23.3, 21.3),
        "solid": '''
  <path d="M7 20 V13.5 A5 5 0 0 1 17 13.5 V20 Z" fill="{S}"/>
  <g fill="none" stroke="{S}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2 20 V9 C2 4 22 4 22 9 V20"/>
  </g>''',
        "outline": '''
  <g fill="none" stroke="{S}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
    <path d="M7 20 V13.5 A5 5 0 0 1 17 13.5 V20"/>
    <path d="M2 20 V9 C2 4 22 4 22 9 V20"/>
  </g>''',
    },
    "orbit": {
        "name": "Orbit",
        "idea": "Traffic slingshots around the network instead of being pulled through its centre.",
        "ink": "#0D9488", "ink2": "#065F55", "bg1": "#04201D", "bg2": "#0B4F47", "accent": "#5EEAD4",
        "bbox": (1.2, 0.5, 22.3, 22.5),
        "solid": '''
  <circle cx="12" cy="12.5" r="4.4" fill="{S}"/>
  <g fill="none" stroke="{S}" stroke-width="2.6" stroke-linecap="round">
    <path d="M2.5 20 C10 23.5 21 20 21 12.5 C21 7 17 4 12.5 4 C10 4 8 4.8 6.5 6"/>
    <path d="M7.2 1.8 L6 6.6 L10.8 5.6"/>
  </g>''',
        "outline": '''
  <g fill="none" stroke="{S}" stroke-width="1.7" stroke-linecap="round">
    <circle cx="12" cy="12.5" r="4.1"/>
    <path d="M2.5 20 C10 23.5 21 20 21 12.5 C21 7 17 4 12.5 4 C10 4 8 4.8 6.5 6"/>
    <path d="M7.2 1.8 L6 6.6 L10.8 5.6"/>
  </g>''',
    },
    "arch": {
        "name": "Arch",
        "idea": "One clean vault over the barrier. The most minimal statement of the whole idea.",
        "ink": "#111827", "ink2": "#374151", "bg1": "#0A0A0A", "bg2": "#2A2A2A", "accent": "#10B981",
        "bbox": (1.2, 8.4, 22.8, 22.3),
        "solid": '''
  <rect x="10.4" y="10" width="3.2" height="11" rx="1.2" fill="{S}"/>
  <g fill="none" stroke="{S}" stroke-width="2.6" stroke-linecap="round">
    <path d="M2.5 20 C2.5 8 21.5 8 21.5 20"/>
  </g>''',
        "outline": '''
  <g fill="none" stroke="{S}" stroke-width="1.7" stroke-linecap="round">
    <rect x="10.6" y="10.2" width="2.8" height="10.6" rx="1.1"/>
    <path d="M2.5 20 C2.5 8 21.5 8 21.5 20"/>
  </g>''',
    },
}

# Apple's macOS icon corner ratio is ~22.5% of the side.
CORNER = 230


def glyph(d, state, colour):
    return d[state].replace("{S}", colour)


def fit(d, box, cx, cy):
    """Transform placing the glyph's optical centre at (cx, cy) inside a `box`-wide square.

    Every surface uses this, so the mark sits identically everywhere instead of each layout
    guessing its own translate/scale (which is how the first pass mis-centred one direction).
    """
    x0, y0, x1, y1 = d["bbox"]
    scale = box / max(x1 - x0, y1 - y0)
    return (f"translate({cx - ((x0 + x1) / 2) * scale:.1f},"
            f"{cy - ((y0 + y1) / 2) * scale:.1f}) scale({scale:.3f})")


def write(name, svg):
    path = os.path.join(OUT, name)
    with open(path, "w") as f:
        f.write(svg)
    return path


for key, d in DIRECTIONS.items():
    # 1. Menu bar template glyphs — pure black, alpha is all macOS keeps.
    for state in ("solid", "outline"):
        write(f"{key}-menubar-{state}.svg",
              f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{glyph(d, state, "black")}</svg>')

    # 2. App icon — squircle, gradient ground, glyph scaled to a 60% optical box.
    write(f"{key}-appicon.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <clipPath id="sq"><rect width="1024" height="1024" rx="{CORNER}" ry="{CORNER}"/></clipPath>
    <linearGradient id="bg" x1="0" y1="0" x2="0.6" y2="1">
      <stop offset="0%" stop-color="{d['bg2']}"/><stop offset="100%" stop-color="{d['bg1']}"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.16"/>
      <stop offset="55%" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <!-- userSpaceOnUse is REQUIRED: an objectBoundingBox gradient has a degenerate box on a
         zero-height path (a horizontal line) and paints nothing at all. -->
    <linearGradient id="mk" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="24" y2="24">
      <stop offset="0%" stop-color="#ffffff"/><stop offset="100%" stop-color="{d['accent']}"/>
    </linearGradient>
  </defs>
  <g clip-path="url(#sq)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#sheen)"/>
    <circle cx="820" cy="180" r="300" fill="{d['accent']}" opacity="0.10"/>
  </g>
  <g transform="{fit(d, 620, 512, 512)}">{glyph(d, "solid", "url(#mk)")}</g>
</svg>''')

    # 3. Wordmark lockup — mark + type, the in-app header.
    write(f"{key}-wordmark.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 120">
  <g transform="{fit(d, 66, 52, 60)}">{glyph(d, "solid", d["ink"])}</g>
  <text x="104" y="76" font-family="-apple-system,Helvetica Neue,Arial" font-size="52"
        font-weight="800" fill="{d['ink']}" letter-spacing="-1.5">VPN</text>
  <text x="212" y="76" font-family="-apple-system,Helvetica Neue,Arial" font-size="52"
        font-weight="300" fill="{d['ink2']}" letter-spacing="-1.5">Bypass</text>
</svg>''')

    # 4. Banner — the repo/README header.
    write(f"{key}-banner.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 320">
  <defs>
    <linearGradient id="bbg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="{d['bg2']}"/><stop offset="100%" stop-color="{d['bg1']}"/>
    </linearGradient>
    <linearGradient id="bmk" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="24" y2="24">
      <stop offset="0%" stop-color="#ffffff"/><stop offset="100%" stop-color="{d['accent']}"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="320" fill="url(#bbg)"/>
  <circle cx="1040" cy="86" r="210" fill="{d['accent']}" opacity="0.10"/>\n  <circle cx="1040" cy="86" r="132" fill="{d['accent']}" opacity="0.07"/>
  <g transform="{fit(d, 132, 150, 160)}">{glyph(d, "solid", "url(#bmk)")}</g>
  <text x="252" y="163" font-family="-apple-system,Helvetica Neue,Arial" font-size="76"
        font-weight="800" fill="#ffffff" letter-spacing="-2">VPN</text>
  <text x="408" y="163" font-family="-apple-system,Helvetica Neue,Arial" font-size="76"
        font-weight="200" fill="{d['accent']}" letter-spacing="-2">Bypass</text>
  <text x="254" y="214" font-family="-apple-system,Helvetica Neue,Arial" font-size="27"
        font-weight="400" fill="#B6C2D4">Send the sites you choose around your VPN. Everything else stays protected.</text>
</svg>''')

print("generated", len(DIRECTIONS) * 5, "svgs")

# --- Render a single contact sheet -------------------------------------------------------
for key in DIRECTIONS:
    for n, w, h in (("menubar-solid", 36, 36), ("menubar-outline", 36, 36),
                    ("appicon", 160, 160), ("wordmark", 400, 92), ("banner", 720, 192)):
        subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h),
                        os.path.join(OUT, f"{key}-{n}.svg"),
                        "-o", f"/tmp/sheet-{key}-{n}.png"], check=True)
print("rendered")
