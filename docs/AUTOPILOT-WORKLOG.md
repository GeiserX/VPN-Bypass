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

## 2026-06-30 — P1 COMPLETE (proxy egress, functional + testable)
Built ADDITIVELY (no risky RouteManager refactor — R1 deferred): separate, independently-tested files.
- **S1** (`d549625`): export credential-strip (sanitizedForExport, version 2.0). Keychain-for-config.json deferred (config.json is user-only; export leak — the acute vector — closed).
- **Rule resolver** (`5f85c55`): pure first-match domain/suffix/service/ip/cidr → route. 9 tests.
- **Proxy primitives** (`9d9f633`): ProxyForwarder (loopback HTTP CONNECT chaining to an upstream proxy, Basic-auth injected, upstream bound to a physical iface to escape the VPN; mock-tunnel test) + HookGenerator (route-on exports + PAC, verified in JavaScriptCore) + CredentialTemplate (Oxylabs/IPRoyal session templates). **Forwarder independently reviewed** (code-reviewer): sound; start() blocks→started off-main; minor benign listener race noted.
- **Listener manager** (`3dab928`): owns a forwarder per enabled proxy route, reconciles on config change. 4 tests.
- **Lifecycle integration** (`8841470`): RouteManager.reconcileProxyListeners() at startup + stopAll on quit; detectPhysicalInterface (route -n get <gw>) for the VPN-escape binding. Additive — no-op without proxy routes.
- **Routes UI** (`3688e13`): new Settings tab (index 2) — add/edit/delete/toggle proxy routes, LIVE listener port (ProxyListenerManager made ObservableObject), Copy-hook button. Delivers the Oxylabs dedicated-ISP use case end-to-end.
- **Evidence:** 9 commits, full suite **594 tests, 0 failures**, every increment built clean. Independent reviews on P0 (caught the applyRoutesFromCache GP-guard gap — fixed) and the forwarder.
- **P0 review fix** (`c80109a`): centralized refuseVPNOnlyUnderGlobalProtect() consulted by all 4 apply paths.

## 2026-06-30 — HANDOFF POINT
- **Done:** P0 (GP-teardown fix, reviewed) + P1 (proxy egress, full UI) — testable now.
- **P1 live test (Sergio):** build+run the branch app → Settings → Routes → add an Oxylabs dedicated-ISP route (disp.oxylabs.io:800X, user/pass) → copy the HTTPS_PROXY block → run in iTerm → `curl ipinfo.io` shows the Oxylabs exit IP.
- **P2 (Tailscale) — NOT built, by design:** the app-side (route a rule's dests into the tailscale utun via iface:utunX) is small, BUT it is non-functional + untestable until the **a tailnet peer advertises those destinations as subnet routes** (tailscaled drops packets otherwise — the research finding) AND it's verified live on the tailnet. So P2 is a quick collaborative step once the mini side is set up — handed off for Sergio's go on approach.
- **Remaining beads:** .5 Keychain-for-config.json (deferred), .6 RouteManager refactor (deferred), .9 P2 Tailscale (handoff), .12 doc update, .11 signing decision / .10 P3 (gated).
- **Release:** NOT cut — Sergio's gate after his live test + go.

## 2026-07-01..02 — LIVE PROOF + experimental gating (logged retroactively; work predates this entry)
- **Live egress proven on Sergio's MacBook** (GP up on utun5, Tailscale utun10, physical en8 gw <lan-gateway>): `LiveProxyEgressTests` (OXY_LIVE=1-gated, upstream read from env — no secrets in repo): forwarder-bound-to-en8 exit IP = the Oxylabs dedicated IP (<proxy-exit-ip>) while direct default-route = <home-wan-ip>. Second test drives the REAL app path — `RouteManager.reconcileProxyListeners()` → stable port **18443** → same Oxylabs exit. Mechanism conclusively escapes the VPN via the app's own lifecycle.
- **Experimental gating** (`abcc61e`): multi-route is opt-in — `multiRouteEnabled` toggle in General; Routes tab hidden otherwise; `reconcileProxyListeners()` hard-gated (`stopAll()` when disabled). Stable per-route ports (18000–18999 derived from route UUID, or explicit `localListenPort`).
- **Helper-independent listeners** (`50cee4b`): proxy listeners start even when the privileged helper isn't ready (userspace path needs no root).
- **Suite:** 596 tests, 2 live-gated skips, 0 failures. 17 commits on `feat/multi-route`. Homebrew app + Sergio's `oxy-on` fallback untouched (dev build NOT hot-swapped — ad-hoc signing would break helper auth).

## 2026-07-03 — NEW DIRECTIVE (GOAL.md continuation): "definitive macOS routing manager"
- Scope expanded: multiple VPNs (rule → a SPECIFIC utun among several), multiple proxies, direct, Tailscale egress (subnet routes now enabled on peer-relay+peer-server-b — P2 unblocked); UX overhaul (classic bypass stays default, vpnOnly stays simple, 3/4-way easy); **scripting surface** (generic verbs — e.g. switch an Oxylabs route's port from a script; NO per-provider integrations).
- PRD rewritten (6 stories US-001..006) in session state; ralph re-engaged.
- 8-agent research panel launched (Tailscale mechanics, UX landscape+scripting prior art, codebase map, history/issues, architecture, live tailnet probe, risk critique, UX design memo).

## 2026-07-01..02 — LIVE PROOF + experimental gating (logged retroactively; work predates this entry)
- **Live egress proven on Sergio's MacBook** (GP up on utun5, Tailscale utun10, physical en8 gw <lan-gateway>): `LiveProxyEgressTests` (OXY_LIVE=1-gated, upstream read from env — no secrets in repo): forwarder-bound-to-en8 exit IP = the Oxylabs dedicated IP (<proxy-exit-ip>) while direct default-route = <home-wan-ip>. Second test drives the REAL app path — `RouteManager.reconcileProxyListeners()` → stable port **18443** → same Oxylabs exit

## 2026-07-03 — research panel synthesized, design LOCKED (US-001 done)
- Panel returned (ts-docs, architect, ux-designer, tailnet-probe + my live tests). Convergent verdict.
- **Live-verified on Sergio's Mac:** GP is split-tunnel (8.8.8.8 → en8); peer-server-b:8080 is a Tomcat
  reverse-proxy NOT a forward proxy (CONNECT→501); no forward proxy anywhere on the tailnet (mini/wt/gct
  ports closed). Tailscale per-destination egress therefore = proxy-over-tailnet (needs tinyproxy on a peer).
- Design doc updated with corrections + locked architecture + UX + scripting + 5-slice build order
  (closes intent of bead .12). Synthesis recap in docs/research/2026-07-03-synthesis.md; raw probe in
  docs/research/2026-07-03-tailnet-probe.md.
- **Next → Slice 1:** Tailscale-peer egress (proxy-over-tailnet), reusing ProxyForwarder with
  boundInterface=nil for tailnet peers; peer picker from `tailscale status --json`; 100.112/12-under-GP
  guard; then stand up tinyproxy on the mini and live-verify a distinct exit IP.
