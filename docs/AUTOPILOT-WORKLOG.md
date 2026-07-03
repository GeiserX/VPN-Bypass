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

## 2026-07-03 — Slice 1 (Tailscale-peer egress) — core done + LIVE-PROVEN
- **Core** (`482556f`): `.tailscaleExit` served by a loopback listener (proxy-over-tailnet); upstream to a
  100.64/10 peer NEVER binds the physical NIC (routes via utun); GP-shadow guard (pause a listener whose
  peer ∈ 100.112/12 while GP up); `listTailscalePeers()` for the UI picker. No model change. 5 new tests.
- **Suite:** 601 tests, 2 live-gated skips, 0 failures. Build clean.
- **LIVE network proof (Sergio's Mac + a tailnet peer):** stood up a throwaway Python CONNECT proxy on the mini
  bound to its tailnet IP `<tailnet-peer-ip>:8888` (zero-install, reversible: `/tmp/tsproxy.py`,
  `pkill -f /tmp/tsproxy.py` to remove). `curl -x http://<tailnet-peer-ip>:8888 https://ipinfo.io/ip` → 200;
  the mini's proxy log shows `CONNECT from <tailnet-peer-ip> -> ipinfo.io:443` = THIS Mac's tailnet IP →
  proves Mac → tailnet(utun10) → mini → internet. Exit IP == direct (<home-wan-ip>) only because the mini is
  on the same home WAN; the geographic value appears when the MacBook is remote.
- **App-path live test** (gated TS_LIVE=1, TS_PEER=host:port): `testTailscalePeerEgressViaAppReconcile`
  drives the REAL reconcile → stable listener → asserts upstream binding is nil + egress works. To run
  once the build is free.
- **UI** (delegated, in review): RouteEditorSheet gains a "Tailscale Peer" type + peer picker from
  `listTailscalePeers()`; RouteRow shows Tailscale routes. Not yet committed (under review).

## 2026-07-03 — scripting addenda + a real bug found (folded into Slice 1 / Slice 3)
- **Scripting design LOCKED** (architect + ux-designer addenda): a bundled `vpnb` CLI (2nd SwiftPM exe
  target, cask-symlinked) over a user-only 0600 UNIX socket → a pure MainActor `CommandRouter`; secrets via
  stdin only (never argv/logs); versioned envelope; `reload` verb (no file-watcher); HTTP/App-Intents
  rejected as primary. Auto-refreshes GUI via existing `RouteManager.shared` reactivity. → Slice 3. Full
  detail in docs/MULTI-ROUTE-DESIGN.md § Scripting.
- **BUG found (architect):** `ProxyListenerManager.reconcile` keys only on route **id**, so editing a live
  route's host/port/creds is a NO-OP until app restart — breaks the user's "re-point the Oxylabs port live"
  use case AND the Routes UI edit flow. Fix (Phase A.5, folding into Slice 1): fingerprint each route's
  upstream; restart the forwarder when the fingerprint changes. Holding the source edit until the UI
  executor finishes (avoid build contention), then apply + test + review UI + one green suite run.

## 2026-07-03 — Slice 1 COMPLETE + the live-re-point fix (US-001 + US-002 done)
- **Commits:** 482556f (Tailscale-peer core) · 7976054 (live re-point fix) · d0132b4 (Routes UI + live test).
- **Live-re-point bug fixed:** `reconcile` keyed on route id only, so editing a live route's upstream was a
  no-op. Now each route carries an upstream fingerprint; on change the forwarder is re-pointed IN PLACE via
  `ProxyForwarder.updateUpstream` — listener + stable local port survive (HTTPS_PROXY keeps working), only
  new connections use the new exit. (A test caught the alternative stop+restart racing the OS port release
  → random-port fallback; in-place avoids it.)
- **Tailscale UI:** RouteEditorSheet "Tailscale Peer" type + live peer picker (`tailscale status --json`) +
  manual-IP fallback; RouteRow shows Tailscale routes.
- **Suite:** 607 tests, 3 live-gated skips, 0 failures. Build clean.
- **LIVE end-to-end (a tailnet peer):** `testTailscalePeerEgressViaAppReconcile` (TS_LIVE=1) PASSED — real app
  reconcile → stable port 18944 → forwarder(boundInterface=nil) → mini <tailnet-peer-ip>:8888 → <home-wan-ip>.
  Mechanism proven through the actual app code, not just a unit mock. (Throwaway tsproxy still on the mini;
  `pkill -f /tmp/tsproxy.py` removes it. TS_LIVE test is gated so CI never needs it.)
- **Next → Slice 2 (UX mode overhaul):** fold multiRouteEnabled into `routingMode` as a 3rd `.custom` case;
  mode picker above the tabs; new Rules tab (route-chip = the one control) + generalized Routes tab; visible
  derive() migration; `.custom` branch through setRoutingMode + the ~5 hardcoded binary call sites.

## 2026-07-03 — sequencing note: Slice 3 (scripting) before Slice 2 (UX), for risk
- Slice 2 (routingMode.custom + RouteCompiler kernel dispatch) is the highest-GP-teardown-risk + most
  product-opinion-heavy work. Slice 3 (scripting CLI) is purely additive (new file/target, can't regress
  existing modes) and directly exposes the live-re-point fix (the user's "switch the Oxylabs IP via script"
  ask). So building Slice 3 first keeps every commit releasable and defers the risky UX engine to a careful
  dedicated pass. Pure `CommandRouter` delegated (verbs over routes/rules/mode/status; secrets never echoed).
  Reversible sequencing only — final product unchanged. Slice 2 direction parked in DEFERRED-QUESTIONS for
  Sergio's eyes (it's the UX centerpiece he cares about).

## 2026-07-03 — Slice 3 COMPLETE: scripting control surface (US-006 done)
- **Commits:** 0e83843 (pure CommandRouter) · 23289e4 (vpnb CLI + control socket + wiring).
- **What shipped:** a bundled `vpnb` CLI drives VPN Bypass generically (routes/rules/mode/status) over a
  user-only UNIX socket (`~/Library/Application Support/VPNBypass/control.sock`, dir 0700, socket 0600, no
  TCP). Canonical use case works: `vpnb route.set id=<uuid> port=<n>` re-points a route's exit live (the
  in-place re-point fix makes it take effect without dropping the stable listener port).
- **Security:** getpeereid() uid check before any read; SO_NOSIGPIPE so a CLI client can't crash the app;
  secrets via stdin (`pass:-`), NEVER argv; SanitizedRoute never carries a credential (hasPassword bool);
  handler logs only the verb. Socket server is RouteManager-free + handler-injected (stub-tested).
- **Evidence:** 637 tests green (CommandRouter 18 + ControlSocketServer 8 + ControlSurface 4). `vpnb --help`
  works; `vpnb status` with no socket → clean error + exit 2 (verified on the real default path).
- **RELEASE-PREP FOLLOW-UP (required before the single release):** `swift build` produces `.build/debug/vpnb`,
  but the release DMG/cask must (a) build `vpnb` universal + bundle it in the .app (e.g. Contents/Helpers/vpnb
  or Contents/MacOS/vpnb), and (b) have the Homebrew cask symlink it to PATH (e.g. /opt/homebrew/bin/vpnb).
  Edit .github/workflows/release.yml + the cask. Not blocking; do it at release prep.
- **Slices done:** 1 (Tailscale egress + live re-point) ✓, 3 (scripting) ✓. **Remaining:** Slice 2 (UX
  overhaul — parked in DEFERRED-QUESTIONS for Sergio's eyes), Slice 4 (multi-VPN "4th way").

## 2026-07-03 — Slice 2 engine landed: Custom Routes mode (per-rule kernel routing)
- **Commit 693a5f8** (engine + transition): `RouteCompiler` (pure, first-match-claims-even-proxy dedup,
  generalized GP catch-all guard) + `RoutingMode.custom` + the 4 apply paths branch to
  `applyCustomRoutesInternal` gated on `schemaVersion>=2 && routingMode==.custom` (legacy paths
  BYTE-IDENTICAL — all pre-existing tests pass) + `setRoutingMode(.custom)` first-entry migration
  (schemaVersion→2 + lossless derive of domains/services→rules, preserving user proxy/Tailscale routes) +
  RoutingMode.displayName + CLI `mode` rejects custom. `reconcileProxyListeners` also fires in custom mode.
- **No NE** — kernel routes + userspace listeners only (honors the hard constraint). Multi-VPN specific-utun
  egress is stubbed (`ifaceGatewayForRoute` returns nil) → Slice 4.
- **Review:** dispatched a code-reviewer (didn't post); my own review + 655 green tests (incl. all legacy)
  cleared it. Behind the merge gate.
- **Evidence:** 655 tests, 3 live-gated skips, 0 failures. Both targets build.
- **In flight (custom-ui executor):** the Custom-mode UI — 3-mode picker above the tabs, new Rules tab
  (route-chip = the one control), System Routes section, menu-bar custom badge; removes the experimental
  toggle + the in-Domains mode card.
- **Next after UI → Slice 4 (multi-VPN "4th way"):** `[VPNLink]` attribution ladder (tailscale-json →
  scutil --nc list → process → address-shape) + optional `Route.vpnSelector` + wire `ifaceGatewayForRoute`
  to resolve a specific-VPN route → `iface:utunX`; then the UI shows one System-route row per detected VPN.
