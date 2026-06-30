# GOAL

> Directive (verbatim — 2026-06-30):
>
> with ralph over P0 until P2 then release just once

---

_Context breadcrumb (pointer, not part of the directive — so "P0 → P2" still means something after a context reset):_

"P0 → P2" are the **Multi-Route Networking** phases, filed as beads under epic **`VPN-Bypass-3sc`** and designed in **`docs/MULTI-ROUTE-DESIGN.md`** (corrections pending). Scope of THIS run:

- **P0** — `routes[]+rules[]` config model + back-compat migration **+ GlobalProtect-teardown hardening** (`VPN-Bypass-3sc.7` + `.1`/`.2`/`.3`/`.4`). No behaviour change.
- **P1** — proxy local-listener egress (Oxylabs) + `route-on` hook (`VPN-Bypass-3sc.8`); prereqs Keychain (`.5`) + RouteEngine refactor (`.6`).
- **P2** — native Tailscale-exit egress via the a tailnet peer (`VPN-Bypass-3sc.9`).
- **"release just once"** — NO per-phase release. One single release after P0–P2 land, via the auto-tag pipeline on merge to `main`, **pending Sergio's merge approval** (release = outward-facing → Sergio-only gate).
- **Out of scope:** P3 / `NETransparentProxy` (`.10`) — gated on the signing decision (`.11`).

Branch: `feat/multi-route`. Loop: `/research! → /implement! → /review-pr!` → back to research.
