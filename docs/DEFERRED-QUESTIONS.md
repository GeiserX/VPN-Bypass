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
