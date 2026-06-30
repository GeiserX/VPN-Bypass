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

## 2026-06-30 — P0.1 + P0.3 done (GP-teardown hardening, part 1)
- **P0.1 single-instance lock** (`VPN-Bypass-3sc.1`, closed): `SingleInstanceGuard` (flock, kernel-released on exit) acquired at launch in `applicationDidFinishLaunching`; duplicate `exit(0)`s WITHOUT quit cleanup so it never removes the running instance's routes. `LSMultipleInstancesProhibited` added to Info.plist. **Evidence:** 2 new unit tests pass (`SingleInstanceGuardTests`), build clean. Commit `19b71bf`.
- **P0.3 block VPN-Only under GP** (`VPN-Bypass-3sc.3`, closed): `applyAllRoutesInternal` refuses VPN-Only (the `0.0.0.0/1`+`128.0.0.0/1` catch-all) when `vpnType == .globalProtect`. Commit `73b81af`.
- **Evidence (both):** full suite **556 tests, 0 failures** (554 prior + 2 new); `swift build` clean. Baseline also compiled (exit 0) before changes.
- Next: P0.7 `routes[]+rules[]` Config model + back-compat `derive()` migration (additive, `schemaVersion=1` so no behavior change). Then P0.2 (diff-before-mutate, safe `forceReassert` variant) + P0.4 (debounce — largely covered by P0.1 + existing 5s/10s cooldowns; minimal). Then P1.

## 2026-06-30 — P0 COMPLETE (model + GP-teardown hardening)
- **P0.7** (`c8d377d`, closed): `routes[]+rules[]` model (`RouteModel.swift`) + Config fields + one-time `derive()` migration; `schemaVersion=1` → no behavior change. 7 tests.
- **P0.2** (`5a88499`, closed): `shouldSkipReapply` no-op skip in `applyAllRoutesInternal` (forceReassert gate; Refresh forces re-assert). 5 tests. Finding: the hourly `backgroundDNSRefresh` already applies deltas only (RM 1993-2068), so the residual churn was redundant full re-asserts — which this skips.
- **P0.4** (`❄ deferred`): churn already bounded by P0.1+P0.2+delta-refresh+flap-suppression+cooldowns+1s network-debounce; cosmetic to unify, and the GP-aware backoff is delicate reconnect-timing needing live-GP validation — not changed blind.
- **Evidence:** full suite **569 tests, 0 failures**; `swift build` clean throughout. 5 commits on `feat/multi-route`.
- **P0 net:** the live GP-teardown bug is fixed (single-instance lock + VPN-Only guard + no-op skip), the multi-route foundation is in place, ZERO behavior change for existing users (schemaVersion=1). Releasable as-is.
- **Now → P1.** Order: S1 Keychain + strip-creds-from-Export (gating security, self-contained, verifiable) → pure rule-resolver (testable) → proxy listener (verify against a LOCAL mock proxy). **Live-verification dependency** (real Oxylabs egress / Tailscale-via-Mac-mini / GP coexistence) recorded in `DEFERRED-QUESTIONS.md` — those can only be confirmed in Sergio's environment, and the single release is his gate.
