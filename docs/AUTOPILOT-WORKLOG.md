# Autopilot Worklog — Multi-Route (VPNBypass)

Append-only. **Newest at the bottom.** Every "done" carries real evidence (build / test / CI / commit).

- **Goal:** `docs/GOAL.md` — "with ralph over P0 until P2 then release just once".
- **Plan:** beads epic `VPN-Bypass-3sc` + children; design `docs/MULTI-ROUTE-DESIGN.md`.
- **Branch:** `feat/multi-route`.
- **Release policy:** ONE auto-tag release after P0–P2 land (on merge to `main`), pending Sergio's approval. No per-phase releases.
- **Loop:** `/research! → /implement! → /review-pr!` → back to research.

---

## 2026-06-30 — kickoff
- 10-agent research panel complete; verdict RESHAPE → tight slice. Plan set: P0 (model + GP-hardening) → P1 (proxy listeners, Oxylabs) → P2 (Tailscale) → single release. P3/NE deferred (signing fork).
- Beads filed: `VPN-Bypass-3sc` (epic) + 12 children.
- Branch `feat/multi-route` cut; beads integration + GOAL/worklog committed. Baseline build check kicked off.
- Next: P0 — start with the GP-teardown hardening (single-instance lock, `VPN-Bypass-3sc.1`) since it's the live-bug fix and lowest-risk, then the `routes[]+rules[]` model + migration (`.7`).
