# Deferred Questions — Multi-Route (VPNBypass)

Items needing Sergio's judgement or his LIVE environment. A reversible default is taken so the loop keeps moving; revisit before the single release.

## 2026-06-30 — Live verification of P1/P2 egress
- **Context:** P1 (Oxylabs proxy egress) and P2 (Tailscale-via-Mac-mini) can be implemented and unit-tested (including the proxy forwarder against a LOCAL mock proxy), but END-TO-END verification needs Sergio's real Oxylabs credentials, a live GlobalProtect session, and the a tailnet peer on the tailnet. Real residential-IP egress, GP coexistence under load, and Tailscale subnet-route forwarding cannot be confirmed autonomously.
- **Default taken:** implement + unit-test the logic; treat live verification as a pre-release checklist item for Sergio.
- **To change:** Sergio runs the P1/P2 features on his machine (pin a destination to an Oxylabs IP; route a destination via the mini) before approving the single release.

## 2026-06-30 — Signing/distribution fork (P3, out of scope this run)
- **Context:** P3 (NETransparentProxy) needs Developer-ID + notarization and dropping the ad-hoc cask resign. Out of scope for P0–P2.
- **Default taken:** defer P3 entirely (bead `.10` blocked on decision `.11`).
- **To change:** Sergio decides the signing fork if/when app-agnostic capture (curl/Go/daemons) is wanted.

## 2026-07-03 — Custom-mode UX direction (Slice 2) — worth Sergio's eyes before it ships
- **Context:** the "really easy UX" centerpiece. The locked design (ux-designer memo) folds the experimental
  toggle into a 3rd routing mode `Custom Routes` (alongside Bypass / VPN Only), with a mode picker above the
  tabs, a new rule-centric **Rules** tab (each rule's route-chip is the one control), and a generalized
  **Routes** tab (System routes auto-detected + Your routes). It also implies a `RouteCompiler` that
  dispatches direct/specific-VPN rules to kernel routes — the highest-GP-teardown-risk change in the whole
  epic (critic + architect both flagged it).
- **Default taken (reversible):** sequence the low-risk additive slices first (Slice 1 Tailscale ✓, Slice 3
  scripting CLI — in progress), and give the risky+opinion-heavy Custom-mode UX its own careful pass. It all
  lands on `feat/multi-route` behind Sergio's merge gate, so nothing ships unseen.
- **To change:** if Sergio wants the UX overhaul prioritized/reshaped, or wants to see a mockup before the
  kernel `RouteCompiler` work, say so. The full spec + copy is in the worklog and docs/MULTI-ROUTE-DESIGN.md.

## 2026-07-03 — vpnb CLI packaging into the release (release-prep, not blocking)
- **Context:** the `vpnb` scripting CLI is a new SwiftPM executable target. `swift build` produces it, but a
  released user only gets it if the DMG/cask ships it.
- **Default taken:** build the feature + tests now; leave packaging for release prep (it's mechanical:
  universal-build vpnb, bundle it in the .app, cask-symlink to PATH).
- **To change:** when cutting the single release, update .github/workflows/release.yml to build+embed `vpnb`
  and the homebrew-vpn-bypass cask to symlink it. (Confirm the bundle location + PATH target with Sergio then.)
