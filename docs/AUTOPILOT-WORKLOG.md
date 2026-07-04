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

## 2026-07-03 — Slice 2 COMPLETE: Custom Routes mode (engine + UI) (US-004 done)
- **Commits:** 693a5f8 (engine + transition) · 727786c (M1 GP-guard hardening) · 14ec388 (UI).
- **Engine review verdict: SAFE — no Critical/High.** Classic bypass/vpnOnly byte-identical (pure-insertion
  branches on all 4 apply paths, verified); GP catch-all guard covers teardown routes + hardened to any
  /0-or-/1 CIDR (M1). M2 (exact-string vs CIDR-containment dedup) documented + deferred to Slice 4. L6
  (stale log label) already fixed by RoutingMode.displayName.
- **UI:** 3-mode picker above the tabs; new Rules tab (route-chip = the one control, drag-reorder, default
  row); System Routes card; menu-bar custom badge + Routes-In-Use; retired the experimental toggle + the
  in-Domains mode card. Fixed a fresh-window-no-selected-tab bug. Window 620→680 for the picker.
- **Evidence:** 657 tests green, 3 live-gated skips, 0 failures. Both targets build. Classic modes untouched.
- **Slices done:** 1 (Tailscale egress + re-point) ✓, 3 (scripting CLI) ✓, 2 (Custom mode UX+engine) ✓.
- **Last feature slice → Slice 4 (multi-VPN "4th way"):** wire `ifaceGatewayForRoute` (currently returns nil)
  to route a rule into a SPECIFIC VPN interface among several: `[VPNLink]` attribution ladder + optional
  `Route.vpnSelector` + resolve to `iface:utunX` + System-routes UI shows one row per detected VPN. Reuses
  the committed engine — no NE.

## 2026-07-03 — Slice 4 COMPLETE: multi-VPN "4th way" (US-003 done) — ALL SLICES DONE
- **Commits:** 1a51caa (engine/model: VPNSelector + listVPNLinks + ifaceGateway, wired into the compiler) ·
  283179a (editor UI: "VPN" type + specific-tunnel picker; specific-VPN routes show their name + live in
  Your Routes; RouteRow "VPN → utunX").
- **Note:** the delegated multi-vpn executor hit a session limit and left no partial work; implemented + tested
  by the orchestrator directly.
- **Mechanism (no NE):** a `.vpnDefault` route pinned to a specific interface resolves (exact name → productHint
  fallback for renumbered utuns → refuse if gone/Tailscale) to an `iface:utunX` kernel route via the existing
  helper primitive. Primary VPN unchanged (nil → no route). GP catch-all guard still runs; a /32 into a foreign
  utun is safe.
- **Evidence:** 660 tests, 3 live-gated skips, 0 failures. Both targets build. Classic single-VPN detection
  untouched (listVPNLinks is additive).

## 2026-07-03 — ALL FOUR SLICES COMPLETE (branch feat/multi-route, 36 commits, 660 green, NOTHING merged)
- **Slice 1** — Tailscale-peer egress (live-proven via the a tailnet peer) + the live-re-point fix.
- **Slice 3** — scripting: `vpnb` CLI over a user-only 0600 UNIX socket (generic verbs, secrets via stdin).
- **Slice 2** — Custom Routes mode: per-rule kernel routing engine (reviewed SAFE, classic modes byte-identical)
  + the 3-mode UX (picker + Rules tab). GP guard hardened (M1).
- **Slice 4** — multi-VPN egress into a specific tunnel among several.
- **The whole thing is entitlement-free** (kernel routes + userspace loopback proxies; NO Network Extension),
  so the app stays ad-hoc-signable. Classic Bypass / VPN Only are the untouched default.
- **REMAINING (Sergio's gate + release prep):** (1) live-test each feature on the real machine; (2) bundle the
  `vpnb` binary into the release DMG/cask (mechanical — see DEFERRED-QUESTIONS); (3) merge → the auto-tag CI
  cuts the single release. Nothing merged; the release is Sergio's explicit go.

## 2026-07-04 — 3.0.1 god-class refactors (branch refactor/routemanager-3.0.1, from main @ 3.0.0)
- **KICKOFF.** 3.0.0 shipped (multi-route + cdhash-pinned helper; release https://github.com/GeiserX/VPN-Bypass/releases/tag/v3.0.0). Now: the 2 deferred god-class refactors of RouteManager.swift (4546 lines), MORE thorough testing, then /review-code! again over different parts. Behavior-preserving; classic modes byte-identical; all 710 tests green after every step. Runner still down (macOS 26/.NET) → local `make release VERSION=3.0.1` fallback.
- Research phase: 2 architects mapping (a) the duplicated apply-tail across the 4 legacy apply paths, (b) the 3-surface config-mutation duplication (RoutesTab/RulesTab/MenuBarViews/ControlSurface).

### Research maps (both architects) — the two extraction plans
- **US-001 apply-tail (RouteManager.swift).** The "4 paths" are really 2 families. IN SCOPE = the full-replace family: `applyAllRoutesInternal` (~1578, tail 1810-1869) + `applyRoutesFromCache` (~2214, tail 2374-2424) share a byte-identical epilogue segments B-F (build newRoutes from allSourceEntries minus failures → two-population orphan cleanup → epoch guard → commit activeRoutes+lastUpdate → hosts). Extract into `private @MainActor func commitAppliedRoutes(routesToAdd:allSourceEntries:batchFailedDests:epoch:logLabel:) async -> Bool` (false=preempted). Keep segment A (helper batch add — DIVERGES: applyAll unconditional+aborts-if-helper-absent; cache wraps in `if !routesToAdd.isEmpty`) and segment G (notify/verify — applyAll only) in each HEAD. Convert applyAll's allSourceEntries 2-tuple→3-tuple (embed gateway per append). Custom twin `applyCustomRoutesInternal` (~1913, tail 1999-2043, byte-identical) = SEPARATE follow-up commit. OUT: the incremental-diff family (backgroundDNSRefresh/performDNSRefresh) — different shape, leave alone. **Trap 7: the suite does NOT drive the apply-tail → prove byte-identity by DIFFING the extracted helper vs the 3 originals, not by green tests.** Other traps: epoch-guard→commit must stay await-free; GP guard + usesCustomEngine dispatch + shouldSkipReapply stay in HEAD before the tail; keep helper @MainActor (not MainActor.run).
- **US-002 centralize mutation (Option B, strictly behavior-preserving).** Add `func reconcileAfterConfigChange(reconcileListeners:reapplyRoutes:sendNotification:=false) async` on RouteManager (NO internal Task). Convert 7 sites, each KEEPS its own saveConfig()+interstitial logs: RoutesTab save/delete/toggle (reconcile:true, reapply:usesCustomEngine), RulesTab.persistAndReapply (false,true), RulesTab.addRoute (true,false), MenuBarViews.addDomainRuleToDirect (false,true), ControlSurface.handle (true, reapply=cmd=="mode"||usesCustomEngine — NO Task, inline await). 8 traps: reapply condition diverges per site (don't unify); ControlSurface mode-disjunct stays; addRoute stays reapply:false; setRoutingMode is separate/heavier (don't touch); NO Task in helper. Implementing now via executor.

### 2026-07-04 — US-002 DONE (mutation centralization) + fixed a 3.0.0 scrub bug
- **US-002 passes.** `reconcileAfterConfigChange(reconcileListeners:reapplyRoutes:sendNotification:)` added on RouteManager; 7 mutation sites converted (Option B, each keeps saveConfig — zero timing change); all 8 traps preserved. Commit c0f56c9.
- **Bonus bug fix (commit d950781):** the 3.0.0 infra-scrub had redacted real IPs inside TEST fixtures (ProxyListenerManagerTests), failing 4 tests in shipped 3.0.0 (app unaffected; CI never caught it — runner down). Restored with synthetic CIDR-correct IPs.
- **710 tests green, build clean.** Next: US-001 (apply-tail extraction, byte-diff verified).

### 2026-07-04 — US-001 DONE (apply-tail extraction, incl. custom-twin fold)
- **US-001 passes.** Extracted the full-replace install-epilogue (segments B-F: build activeRoutes → two-population orphan cleanup → epoch guard → commit → hosts) into `private @MainActor commitAppliedRoutes(...)`. 3 copies → 1 helper: applyAllRoutesInternal + applyRoutesFromCache (c38322d) + applyCustomRoutesInternal (d56ba67). Byte-diff verified: routesToAdd (kernel batch) byte-identical; allSourceEntries gained a gateway field embedding each entry's paired-routesToAdd gateway (provably identical — RouteCompiler claims each dest once). Only cosmetic log-case deltas. RouteManager 4555 → 4484 (-71). 710 green incl. 42 custom-engine tests. The DNS-refresh family (backgroundDNSRefresh/performDNSRefresh) is a different incremental-diff shape — left alone (correct).
- **Next: US-003 thorough testing** — close Trap 7 (the suite doesn't drive the apply-tail): extract the PURE orphan-cleanup set algebra into a testable seam + cover it; broaden edge-case coverage of the pure seams.

### 2026-07-04 — US-003 DONE (thorough testing) + US-004 DONE (/review-code! whole-repo)
- **US-003 passes.** Closed Trap 7 by extracting the pure orphan-cleanup set algebra into `partitionStaleRoutes(active:applied:attempted:)` (nonisolated static) + 11 tests; added ~50 edge-case tests across the pure seams (RouteCompiler, RuleResolver, ConfigDerive, CredentialTemplate, IfconfigParser, IfaceGateway, RuleDestinationBuilder, HookGenerator, ProxyForwarder). Suite **710 → 773**.
- **US-004 passes — 7-auditor /review-code! over the whole codebase**, weighted to parts not covered in the 3.0.0 pass (lifecycle, helper state machine, DNS-refresh family, hosts/notifications/detection, config migration) + a dedicated refactor-verifier.
  - **Release gate GREEN:** refactor-verifier confirmed the 3.0.1 refactors are **byte-identical / behavior-preserving** for every realistic config (only cosmetic log-string + a harmless degenerate-config in-memory label diff). No leak risk from the refactor.
  - **Fixed (safe, verified — clean build, 773 green):** log subsystem moved off world-readable `/tmp` to `~/Library/Logs/VPNBypass/` (0700 dir, O_NOFOLLOW+0600) with a cached formatter + persistent handle (closes perf-CRITICAL B1 + the security /tmp finding); `print`→shared logger in HelperManager/NotificationManager (helper/notify failures now reach the log); saveDNSCache/loadDNSCache surface errors + 0600; helper version probe distinguishes timed-out(slow) vs unreachable(broken) + retries once before reinstall; DNS resolver losers killed on cancellation; flap-sleep honors cancellation; cdhash-pin escaping unified; ~12 dead symbols removed (interfaceTypeName, applyRouteForRange, updateNetworkStatus, detectAndApplyRoutes, showOnTop, clearHostsFile, HelperProgressProtocol, hasPromptedKey, hasCompletedInitialStartup, lastSuccessfulVPNCheck, unused import); test-quality (ThemeTests assertions, mislabeled DNS test, de-tautologized partition tests).
  - **Deferred → docs/CODE-REVIEW-3.0.1.md** (NOT in a behavior-preserving patch; each needs on-device testing or is behavior-risking on the leak-critical path): audit-token XPC caller auth (HIGH, root helper — needs admin-install test), timeout→orphaned-route kernel reconcile (HIGH — leak-critical teardown), apply-head + DNS-engine unification + classic-mode compiler extraction & apply-path integration tests, helper addRoutesBatch parallelization, DNS concurrency cap, god-class split, quit-cleanup ordering, helper re-validation watchdog, airport→CoreWLAN, isValidCIDR alignment, and the never-firing 1.3.0 service/domain notifications (product call).
- **US-006 passes.** README rewritten for the 3.0 routing-manager reality (3 modes, routes/rules, multi-egress: multi-VPN + HTTP/SOCKS5 proxy + Tailscale-peer, the `vpnb` CLI, 7 tabs, cdhash-pinned NE-free helper) — no infra leak, no overstating. CHANGELOG (3.0.0 + 3.0.1), ROADMAP, MULTI-ROUTE-DESIGN, Helper/Info.plist version all refreshed.
- **REMAINING:** US-005 (Sergio's gate) — open the PR, address CodeRabbit, ship 3.0.1 ONLY on explicit approval. Runner still down → local `make release VERSION=3.0.1` fallback if needed.

### 2026-07-04 — scope expanded to "fix everything incl. deferred"; hardening pass shipped
- Sergio: "Include all this into 3.0.1, fix everything even the things you flagged to defer, test thoroughly" + "if you need 3.1.0 do it as a minor, delicately as always."
- **Shipped + verified (786 tests, 0 failures, 0 warnings on a clean rebuild via machost), pushed to PR #55:**
  - **US-007** `ClassicRouteCompiler` — pure, exhaustively-tested classic Bypass/VPN-Only route builder (the leak-critical default path's test net). applyAllRoutesInternal + applyRoutesFromCache both use it. Set-equivalent (only the deduped route set is observable; commitAppliedRoutes reads only .destination). +13 tests.
  - **US-008** cache path folded onto the compiler — apply head has one definition.
  - **US-011** timeout→orphaned-route LEAK fixed (indeterminate teardown so attempted routes are recorded + removed) + updateHostsFile returns Bool so hosts-write failures are surfaced not logged as success.
  - **US-012** DNS resolution capped with a 16-wide sliding window (no ~500-subprocess fork-storm).
  - **US-014** removeAllRoutes tears down catch-alls first (survives a time-capped quit); documented the CLI-vs-GUI isValidCIDR difference as intentional (match-pattern /0 vs route-dest /0), NOT drift — a review false-positive.
  - build hygiene: redundant `await` + test actor-isolation → 0 warnings.
- **HELD for Sergio (delicately — see docs/CODE-REVIEW-3.0.1.md Status block):** audit-token XPC (root helper, brick-risk, can't live-test — this is the `feat:` that would make it 3.1.0; without it the batch is a 3.0.1 patch); god-class split US-013 (recommend separate PR); DNS-refresh unification US-009 (apply path not suite-exercised); helper addRoutesBatch parallelization; US-014 leftovers (watchdog / CoreWLAN / notifications / timer-cancel).
- **Version:** ships as **3.0.1** (patch) since the feature-like audit-token is deferred; becomes 3.1.0 when it lands. Asked Sergio (audit-token handling + god-class-split sequencing) — no answer in 60s, took the reversible/delicate defaults.
- **NOT merged** — Sergio's release gate. CodeRabbit to be addressed on the grown PR.

### 2026-07-04 — 3.1.0 SHIPPED (free CI); 3.2.0 roadmap set
- **3.1.0 released** on free macos-latest: release v3.1.0 + DMG + cask (3.1.0). Audit-token (self-validated on the mini) + config-model extraction. Both 3.0.1 and 3.1.0 now shipped, $0 CI, dead runner gone.
- Branch feat/routemanager-3.2.0 created off main (8c3dbbc). (Caught + fixed a stale-origin/main reset that had briefly based it on 3.0.1.)
- **3.2.0 backlog (all leak-critical or large — do with fresh care, self-test each on the mini which is now a proven test env):**
  1. God-class split cont'd: extract the STATEFUL collaborators (VPNDetector, RouteApplier, ConfigStore, DNSResolver) — high churn on the @MainActor apply/detect logic. (Model extraction already done in 3.1.0.)
  2. US-009: unify the two DNS-refresh engines; make the recurring timer use the parallel resolver (not the serial one). Apply path not suite-exercised → mini self-test.
  3. Helper addRoutesBatch parallelization (perf; privileged, leak-critical).
  4. US-014 leftovers: helper re-validation watchdog (mini-testable); airport→CoreWLAN (needs a Location-permission decision); the never-firing 1.3.0 service/domain notifications (product call: wire vs remove); withXPCDeadline timer-cancel (micro-opt on the XPC-hang primitive).
- Mini self-test recipe (proven): copy RC app → sudo-install helper (replicate installHelperLegacy) → launch → read ~/Library/Logs/VPNBypass/vpnbypass.log for "Helper installed: true" / route application → clean up (bootout + rm helper/pin/plist).
