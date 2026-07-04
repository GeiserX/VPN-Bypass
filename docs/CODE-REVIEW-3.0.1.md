# Code Review — 3.0.1 (whole-codebase audit)

*Point-in-time record of the multi-perspective review run on the `refactor/routemanager-3.0.1`
branch. It captures what the review changed, and — more importantly — the hardening work that was
**deliberately deferred** out of a behavior-preserving patch release, so it is not lost.*

Overall health at review time: solid, correct routing core (the 3.0.1 refactor is verified
byte-identical to 3.0.0 — no leak risk), carrying maintainability debt (a large `RouteManager`),
some hot-path inefficiency, thin coverage of the imperative apply paths, and a documentation lag.

---

## Fixed in 3.0.1 (safe, behavior-preserving hygiene)

- **Log subsystem** — the debug log moved off the world-readable, symlink-plantable `/tmp/vpnbypass.log`
  to an owner-only file under `~/Library/Logs/VPNBypass/` (`0700` dir, `O_NOFOLLOW` + `0600` file), and
  the per-line cost was removed: one shared `ISO8601DateFormatter` and one persistent append handle
  instead of allocating a formatter and opening/seeking/closing on every line.
- **Logging consolidation** — `HelperManager` and `NotificationManager` previously logged only via
  `print()`, so helper install/update/XPC failures and notification failures never reached the log file
  or the in-app Logs tab. They now route through the shared logger, so field failures are diagnosable.
- **Silent-failure fixes** — `saveDNSCache`/`loadDNSCache` now surface encode/write/corruption errors
  (and the cache file is written `0600`) instead of swallowing them; the helper version probe
  distinguishes "timed out (slow)" from "unreachable (broken)" and retries once before reinstalling, so
  a merely-busy helper no longer triggers a spurious admin-password prompt.
- **Dead code removed** — `interfaceTypeName`, `applyRouteForRange`, `updateNetworkStatus(NWPath)`,
  `detectAndApplyRoutes()` (sync wrapper), `showOnTop()`, `clearHostsFile()`, the unused
  `HelperProgressProtocol`, the vestigial `hasPromptedKey` flag, the write-only
  `hasCompletedInitialStartup` / `lastSuccessfulVPNCheck`, and an unused `import UserNotifications`.
- **Small hardening** — the losing DNS resolvers in a race are now killed on cancellation instead of
  running out their full timeout; the flap-recheck sleep honors cancellation; the modern-path cdhash pin
  uses the same uniform shell/AppleScript escaping as the legacy installer.
- **Docs** — CHANGELOG gained the missing `[3.0.0]` and `[3.0.1]` entries; ROADMAP and
  MULTI-ROUTE-DESIGN were corrected (v3.0 current state, the `vpnb` CLI marked shipped, and the routing
  engine described as the entitlement-free path — **no Network Extension** — rather than the previously
  documented `NETransparentProxy`); stale header comments and the helper `Info.plist` version were fixed.
- **Tests** — no-assertion `ThemeTests` were given real assertions, a mislabeled DNS-display test now
  asserts its default, and the stale-route partition tests were de-tautologized to assert hand-computed
  expected sets. Suite stays green.

---

## Deferred hardening milestone (not in 3.0.1)

These are real findings. They were **not** applied in 3.0.1 for one of two reasons: (a) they change
behavior on the leak-critical routing/helper paths and would break the "strictly behavior-preserving"
contract of this release, or (b) they need real on-device testing (admin install, live VPN) that a
patch release should not gamble on. Each is worth doing as its own scoped, verified change.

### Security

- **XPC caller auth uses PID, not audit token** — `Helper/HelperTool.swift` (`verifyCallerIdentity`,
  `kSecGuestAttributePid`). PID-based `SecCode` validation is subject to a PID-reuse race; because both
  the identifier and the pinned cdhash are checked against whoever currently owns that PID, a successful
  reuse also satisfies the cdhash pin. **Fix:** validate the connection's kernel audit token
  (`kSecGuestAttributeAudit` via `NSXPCConnection.auditToken`) instead of the PID, keeping the same
  requirement string. Touches the root helper → must be admin-installed and XPC-round-trip tested on a
  real machine before shipping; keep an identifier-only fallback so it can never brick.
- **Defense-in-depth:** reject `/0`–`/1` destination masks in the helper's `isValidDestination` unless a
  catch-all is explicitly required by the active mode, so a single accepted call can't hijack the
  default route.
- **DNS answers are trusted into routes + `/etc/hosts`** with only IPv4-well-formedness validation
  (`resolveIPsParallel`). Consider preferring the authenticated DoH resolvers as the source of truth on
  untrusted networks, or requiring two independent resolvers to agree before persisting/routing an IP.
- **Config/backup are written `0644` then `chmod 0600`** (brief world-readable window) — switch to
  atomic create-at-`0600`. Mitigated today by `~/Library` being `0700`.

### Correctness / error handling

- **Timed-out helper batch is reported as all-failed → orphaned kernel routes** — `HelperManager`
  `addRoutesBatch`/`removeRoutesBatch` deliver an all-failed fallback on deadline, but a merely-slow
  helper still installs the routes; nothing records them, and there is no kernel-route reconciliation, so
  they can outlive disconnect and quit (a silent leak). **Fix:** treat a timed-out batch as
  *indeterminate* — record the attempted destinations so teardown still removes them, or add a
  kernel-route reconcile pass. Leak-critical teardown path → needs live testing.
- **`updateHostsFile` returns `Void`; callers ignore failure** — a hosts-write failure is logged but the
  flow still reports success and marks the refresh complete, so `/etc/hosts` silently drifts from the
  kernel routes. **Fix:** propagate `(success, error)` up so the completion status reflects a partial
  failure.
- **Helper readiness is validated once at launch and never re-checked** — a mid-session helper death
  leaves the UI showing "Installed" while every route op eats a 10 s XPC timeout. **Fix:** have the
  watchdog re-probe `getVersion` periodically and transition off `.ready` on repeated failure.
- **Quit can orphan the VPN-Only catch-all routes** — the 8 s terminate cap can win the race against
  `cleanupOnQuit`. **Fix:** remove the `0.0.0.0/1` + `128.0.0.0/1` catch-alls first in cleanup so a
  capped quit can't leave a full-tunnel-defeating route installed.

### Architecture / maintainability (behavior-risking — do behind the test net below first)

- **`RouteManager` is a ~4.5k-line god class** with the data model (`Config`, `RoutingMode`, `VPNType`,
  `ServiceEntry`) nested inside the `@MainActor` class, forcing the "pure" `CommandRouter`/CLI to reach
  into its namespace. **Fix:** extract the model to a leaf module, then split along the MARK seams
  (`VPNDetector`, `DNSResolver`/`DNSCache`, `ConfigStore`, `RouteApplier`).
- **The apply "head" is copy-pasted across 4–5 engines** — the VPN-Only catch-all injection and the
  `routesToAdd`/`seenDestinations`/`allSourceEntries`/`seenSourceDests` dedup quartet. The 3.0.1 refactor
  unified the *tail* (`commitAppliedRoutes`); the head still diverges by hand. **Fix:** extract a single
  route-collection helper shared by all engines.
- **Two divergent DNS-refresh engines** — `backgroundDNSRefresh` (parallel, startup-only) vs
  `performDNSRefresh` (serial, the recurring timer + Refresh button). Any reconciliation fix must be made
  twice, and the recurring path is the slow one. **Fix:** unify onto one parallel implementation.
- **App↔helper contract shared by file inclusion** — `HelperProtocol.swift` lives inside the AppKit
  module but is also compiled into the daemon by the Makefile with an unenforced "Foundation-only"
  invariant. **Fix:** move it (plus `HelperConstants`) into a tiny leaf module both builds depend on.
- **Startup ordered by a hardcoded 3.0 s sleep** against an unbounded admin prompt, with detection
  writes not serialized against the startup pass. **Fix:** an explicit startup-complete gate.

### Performance (scales with route/domain count)

- **Helper `addRoutesBatch` does serial delete-before-add** (~0.14 s/route) → hundreds of routes take
  tens of seconds with the apply gate held. **Fix:** parallelize/batch the helper-side `/sbin/route`
  work (careful — privileged, leak-critical).
- **Unbounded ~500-way `dig`/`curl` fan-out** with no concurrency cap. **Fix:** a `DispatchSemaphore`
  bound on concurrent resolver subprocesses.
- **`checkVPNStatus` (30 s timer)** shells `tailscale status --json` three times per cycle and bypasses
  the `ensureGateway` cache. **Fix:** fetch the Tailscale JSON once per cycle and thread it through;
  honor the gateway cache. Also coalesce concurrent `checkVPNStatus` invocations.
- **`verifyRoutes` pings up to 10 hosts serially (up to 40 s) inside the held apply gate.** **Fix:**
  bounded `TaskGroup`, and run it outside the gate.
- **`detectCurrentNetwork` shells the `airport` binary Apple removed in macOS 14+** — always fails and
  forks a doomed process every 30 s. **Fix:** `CoreWLAN` (`CWWiFiClient`) — note this needs Location
  authorization for SSID on recent macOS.
- **`withXPCDeadline` never cancels its fallback timer on success** — needless scheduled work per call
  (minutes out for batch ops). Low value; the exactly-once primitive it lives in is safety-critical, so
  touch it carefully.

### Test coverage (the highest-leverage structural gap)

- **Every imperative route-mutating path in the default Bypass/VPN-Only engine is unexecuted by tests**
  — they are gated behind `isVPNConnected`, which is hard-wired `false` in tests, so `applyAllRoutesInternal`,
  the VPN-Only catch-all injection, `refuseVPNOnlyUnderGlobalProtect`, the `commitAppliedRoutes`
  epilogue, `checkVPNStatus` disconnect/flap, and `performDNSRefresh` all ship green regardless of
  regressions. **Fix (unlocks the architecture work above):** extract classic-mode route-building into a
  pure compiler mirroring `RouteCompiler`, unit-test it, and inject a mock `HelperManager` so at least
  one end-to-end apply/teardown runs with `isVPNConnected = true`.

### Product decisions (need a call, not just code)

- **Service/domain-toggle notifications advertised in CHANGELOG [1.3.0] never fire** — the
  `NotificationManager` methods `notifyServiceToggled` / `notifyDomainAdded` / `notifyDomainRemoved`
  (plus `notifyNetworkChanged`, `sendTestNotification`, `openNotificationSettings`,
  `checkAuthorizationStatus`) have zero call sites. Decide: re-wire the feature at the toggle sites, or
  remove the methods and drop the claim.
- **`isValidCIDR` accepts `/0` in the `vpnb`/CLI path but rejects it in the GUI path.** Pick one rule
  (does Custom mode legitimately need a `0.0.0.0/0` rule?) and share a single validator.
