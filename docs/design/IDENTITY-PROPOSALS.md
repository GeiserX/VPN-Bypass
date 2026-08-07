# Visual identity — four directions to choose from

Pick **one direction**. Each one is a complete, unified system: the same mark drives the menu
bar glyph, the app icon, the wordmark and the banner, so nothing drifts. Every asset here is
generated from a single source (`generate.py`), which is what guarantees they stay consistent.

---

## All four, every surface

![Four directions across every surface](images/directions-grid.png)

Each block shows, left to right: **menu bar (active)** · **menu bar (idle)** · **app icon** ·
**wordmark** — then the **banner** underneath.

---

## The decision that matters most: the menu bar at real size

An 18-pixel glyph is where most icons fall apart, so judge here first. This is actual size, on
both a light and a dark menu bar, with the active and idle state of each direction side by side:

![Menu bar icons at actual size](images/menubar-actual-size.png)

---

## No more ON / OFF badges

The old menu bar showed a route count and the dropdown showed an **ON/OFF** pill. Both are gone
in these proposals:

- **The count is removed.** It moved with DNS churn rather than with anything you did, so at a
  glance it was noise.
- **State is the same mark, filled or hollow.** Solid = actively routing. Hollow = idle or no
  VPN. One shape, two weights — nothing flips to a different icon, and there is no badge.
- A problem (helper down, nothing being enforced) is the only case that changes anything more,
  and it is stated in words in the dropdown rather than encoded in a glyph.

---

## The four directions

### 1. Lanes — precise, technical, unmistakable
![Lanes](images/lanes-banner.png)

Two routes leave together. One passes straight through with an arrow; the other stops at a wall.
It is the literal picture of what the app does, and it is the easiest of the four to read
instantly at any size.

**Palette:** electric blue `#2563EB` on deep navy. **Feels like:** a precision network tool.

### 2. Tunnel — the strongest silhouette
![Tunnel](images/tunnel-banner.png)

The solid arch is the VPN tunnel; the line vaults over the top of it instead of going through.
The heaviest, most distinctive shape of the four — the clearest at 18px, and the one most likely
to be recognised at a glance in a crowded menu bar.

**Palette:** indigo `#4F46E5` into violet. **Feels like:** infrastructure, something solid.

### 3. Orbit — dynamic and modern
![Orbit](images/orbit-banner.png)

Traffic slingshots around the network core rather than being pulled through it. The most
energetic of the four and the most "brand-like" rather than diagrammatic.

**Palette:** teal `#0D9488` with mint. **Feels like:** modern, fast, a bit playful.

### 4. Arch — the minimalist
![Arch](images/arch-banner.png)

A single clean vault over a barrier. The most restrained option: nearly monochrome, with one
signal-green accent.

**Palette:** graphite with signal green `#10B981`. **Feels like:** understated, developer-tool.

---

## My recommendation

**Tunnel** if you want the icon to be unmistakable at a glance — it has the most presence at
18px and the arch is the most ownable shape here.

**Lanes** if you would rather the icon *explain itself* — it is the most literal depiction of
"one route goes through, one goes around", and blue reads as a networking tool.

Orbit is the best-looking at large sizes but slightly the busiest small. Arch is the most
tasteful and the least memorable — it reads as a letterform before it reads as a mark.

---

## What happens after you choose

The chosen direction replaces, in one change: the menu bar glyphs (all states), `AppIcon.icns`
at every required resolution, the in-app wordmark, the README banner, and the Docker/GitHub
social preview. Nothing else needs touching, because everything derives from the one mark.
