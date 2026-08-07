# Improvement Plan — August 2026

This plan comes out of an eight-lens investigation (code tracing, the VPN client's own logs,
XNU source, Palo Alto primary documentation, and how Mullvad / Tailscale / OpenVPN / WireGuard
solve the same problems). Everything below is anchored to verified evidence; nothing is
speculative architecture.

**Product priority, in order:**

1. A user with one corporate VPN and a handful of bypassed domains gets a **flawless, honest**
   experience with zero configuration.
2. Complex machines (a corporate VPN plus a mesh VPN plus local proxies) degrade **safely and
   visibly** — and must never corrupt the simple case.
3. Power-user controls come after the first two.

---

## What the investigation established

### The route-write "burst" was never the problem

The corporate VPN client we tested against debounces route changes (3 seconds, documented by the
vendor) and explicitly skips network discovery when its tunnel is undisrupted. During two full
~317-route applies it logged zero errors and zero drops, and it skipped discovery on **761 of
761** route-change notifications in a day. Write *count* and write *rate* are not what hurts it.

### The real failure is subprocess contention

Every tunnel drop in the client's own logs (73/73) followed one chain: the client spawns a
subprocess to *read* the route to its gateway; when that read **times out**, it wrongly infers
"gateway route removed" and tears the tunnel down. All of those timeouts occurred while our
helper was wedged — stacked `/sbin/route` processes, XPC timeouts. Each `/sbin/route` invocation
is a fork+exec that opens its own routing socket and blocks with no timeout; stacked invocations
starve everyone else's route operations, including the VPN client's.

Two designs make this structurally impossible (Mullvad's `talpid-routing` is the reference): one
owned `PF_ROUTE` socket, monotonic sequence numbers, a hard response timeout. Tailscale already
migrated off subprocesses on Linux for related reasons.

### Kernel facts that constrain the design (verified in XNU source)

- One route mutation = one routing-socket broadcast to every listener. **Failed** operations
  broadcast too — a speculative delete-before-add is two events even when both are no-ops.
- `route get` also broadcasts (and forks). The silent alternatives: `sysctl NET_RT_DUMP` reads
  the whole table in one syscall with **zero** events and zero forks.
- There is no kernel facility to batch, coalesce, or mute routing-socket notifications.
- `RTF_PROTO1` is userland-settable, persists, and is visible in `netstat` and in dumps — a
  usable ownership tag. `RTF_PROTO3` is the kernel's own GC marker (`RTPRF_OURS`) and must
  never be set.
- Interface-scoped (`-ifscope`) routes are invisible to ordinary unbound-socket traffic —
  verified live — so they cannot implement bypass steering. Traffic through a socket bound with
  `requiredInterface` (our proxy listeners) *is* steerable that way, with zero route writes.
- PF `route-to` in a named anchor emits zero routing-socket events, but the outbound PF hook
  runs after source-address selection, so it needs NAT to work under a full tunnel — a spike,
  not a substitution.

### The quit-path races are proven, with two distinct holes

1. Teardown deliberately skips the operation gate and relies on an epoch bump so in-flight work
   aborts itself — but the abort check runs *after* the kernel batch-add, and quit kills the
   process before the compensating removal runs. Routes then exist in the kernel with **no
   record in memory**, invisible to any future teardown.
2. Quitting *during* a startup apply finds the tracked-route list still empty, so teardown is
   skipped entirely, the epoch never bumps, and the in-flight apply finishes installing its full
   set after "cleanup" completed.

The SIGTERM path (which `brew upgrade`'s `pkill` takes) performs none of the timer/monitor stop
calls the normal quit path performs.

This is almost certainly the mechanism behind issue #67 ("public IP shows my real country while
the app is on"): a stranded route — or worst-case stranded VPN Only catch-alls — surviving an
unclean quit. The reporter used the app correctly; the defect class is ours.

### The UI is not honest when enforcement fails

With the helper not ready, the menu shows a green "ON" pill and "VPN Connected" while **zero
routes are enforced**; the Refresh button silently does nothing; no notification fires
(`notifyEnforcementFailed` exists but is not wired into the startup bail-out); `vpnb status`
returns config only, so even scripts can't ask "are you actually enforcing?".

### Coexistence status (already shipped vs missing)

Shipped: deterministic interface selection (prefers the default-route tunnel, never Tailscale,
sticky, numeric tie-break); loopback and the Tailscale ranges refused inside the root helper, so
local proxy listeners can never be routed in any mode.

Missing: any user-visible pin ("act only on this tunnel"), any coexistence diagnostics, CLI
parity for the existing per-route tunnel selector, and links to `docs/COEXISTENCE.md` (currently
orphaned). A pin by **product name** ("only GlobalProtect") is not honestly buildable today —
nothing attributes a utun to a VPN product; pin by **interface with a durable product-label
fallback** already exists at route level (`VPNSelector`) and is the mechanism to reuse.

---

## The plan

### Phase 0 — Correctness: close the quit races (small, highest urgency)

1. Synchronous `isShuttingDown` flag; set as the first statement of both quit paths and checked
   inside the single operation-gate function (covers every gated mutation entry in one edit).
2. Always run teardown on quit — drop the `if !activeRoutes.isEmpty` guard so the epoch always
   bumps and an in-flight apply is always preempted.
3. Record destinations into a shutdown-visible pending set **before** every kernel batch-add, so
   final teardown can remove routes the in-memory model never got to track.
4. Own and cancel the detached DNS-refresh task; cancel retry chains at quit start.
5. Unify the SIGTERM path with the normal quit path (one `beginShutdown()`).
6. Fix the quit deadline under-sizing when quit lands mid-apply.

### Phase 1 — Root cause: eliminate subprocess contention (medium)

7. **Helper 2.0 route engine**: replace `/sbin/route` execs with one owned `PF_ROUTE` socket —
   `rt_msghdr` writes, monotonic `rtm_seq`, errno from `write(2)`, hard timeout, serialized.
   Porting gotchas are documented (4-byte ROUNDUP, trimmed netmask `sa_len`, positional
   sockaddrs, correct RTF flag composition, `shutdown(SHUT_RD)` on the write socket).
8. **Silent verification**: replace all per-route `route get` checks with one `NET_RT_DUMP`
   snapshot; diff per-route and write only genuine differences; never delete-before-add.
9. **Ownership tags**: set `RTF_PROTO1` on every route we create.
10. **Sweep-by-signature at every startup** (and on demand): remove any `RTF_PROTO1` route we
    did not intend — the industry-standard crash/unclean-quit recovery (Tailscale's model), and
    the permanent fix for the issue #67 class. No disk journal; the kernel *is* the journal once
    routes are self-identifying.
11. **Protect the VPN's own gateway route**: never write to the detected VPN gateway host route
    (vendor-documented connect-then-flap if it's disturbed).

### Phase 2 — Honest UX for the core persona (small-medium)

12. Surface helper/enforcement state in the menu: no green "ON" unless routes are actually
    enforced; a clear "helper not ready — click to fix" state; wire `notifyEnforcementFailed`
    into the startup bail-out; make Refresh report failure.
13. First-run: a short "nothing is configured yet" state pointing at Settings, instead of a
    silent empty config behind an admin prompt.
14. `vpnb status --runtime`: helper state, selected tunnel, enforced route count, last error.
15. Diagnostics card (on-appear refresh only): every up tunnel, which one we act on, which
    carries the default route, which is Tailscale, and the routes we own (by tag). Copyable as
    a diagnostics bundle for issue reports.
16. Issue #67 follow-up: ask for the one discriminating command (`netstat -rn` catch-all check),
    and close once the Phase 0+1 release ships the structural fix.

### Phase 3 — Power users, without endangering the simple case (small each)

17. Optional pin: "act only on tunnel X" — constrains the selector's candidate set, **never**
    outranks default-route observation; warn visibly when pin and observation disagree.
18. CLI parity for the existing per-route `VPNSelector` (today `vpnb` can neither set nor even
    display it; unknown egress strings silently map to `proxyHTTP` — make that an error).
19. Retire or wire up the orphaned `multiRouteEnabled` flag; fix the stale doc reference and the
    unused `hintType` parameter.
20. Link `docs/COEXISTENCE.md` from the README and the in-app Info tab.

### Phase 4 — Spikes (optional, gated on evidence of need)

21. PF `route-to` in a named anchor for destinations where a route write is most dangerous —
    budget for the source-address/NAT problem and `/etc/pf.conf` persistence before writing any
    code.
22. Steer more traffic through `requiredInterface`-bound proxy listeners — the only mechanism
    with literally zero routing activity.

---

## Verification gates

- Phase 0: a kill-during-apply harness leaves zero untracked kernel routes (checked via dump).
- Phase 1: one full apply/remove cycle spawns **zero** `/sbin/route` processes; a table dump
  shows every one of our routes tagged; a simulated crash is fully cleaned by the next start's
  sweep.
- Phase 2: with the helper deliberately broken, the menu must not show green; `vpnb status
  --runtime` must say enforcement is down.
- Regression: the corporate-VPN client's log shows zero route-read timeouts across a full
  apply + refresh + quit cycle.
