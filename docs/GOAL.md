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

## 2026-06-30 — continuation (verbatim)

> do all the work but lets test at the end aftwr you do all the three phases, wait for my to-go

_Interpretation: implement ALL of P0→P1→P2 autonomously (unit-test + mock-verify as I go); Sergio does the LIVE testing (real Oxylabs egress, Tailscale-via-mini, GP coexistence) at the very end; do NOT merge or cut the single release until Sergio gives the explicit "to-go" after his test._

## 2026-07-03 — continuation (verbatim)

> Okay so continue with the issue you had open in the repository, that's the /goal
> so /sergio-loop until you have a perfect version of the vpn bypass app where you can configure multiple vpns, multiple proxies, also direct... etc. So from UX perspective, it's really easy to do it.
> Obviously, make the current way of work of vpn/direct split to continue being the default, so it's not difficult for people to just select the old plain split vpn/direct, that's the app what's for, but cater to users like me that need a three way split, or even fourth way... so think and research well how to properly do this as this is extremely difficult think to do, and i expect you to throw all what you have into this problem
> obviously we still suport what other user wanted which is the only select the vpn for specific domains, and by default just use direct. that's also really interesting. in the end I want vpn bypass to become the definitive routing manager in macos for all your needs

## 2026-07-03 — continuation 2 (verbatim, same day)

> Also I want even to support scripts so that people can via scripting modify the behavior of vpn bypass somehow (if it's secure, better, but whatever you can get) so that for exammple (just in my case) i want to select one oxylabs route for a given domain, but maybe i want to change the routing ip and use another, so i can have it via script (ideally, this should be also easily via vpn bypass, but i dont want to be supporting integrations with all kind of proxy services or vpns, so its just fyi to scope it well)

## 2026-07-03 — continuation 3 (verbatim, same day)

> Just continue to /sergio-loop over these slices with ralph

> Continue using these quirks with pf, CA, etc... I don't want to be using NE entitlements or anything for this

## 2026-07-04 — continuation (3.0.1 refactors + review)

> over the god class refactors 3.0.1 and do even more thorough testing too also do /review-code! when you finish again over all the code focusing on different parts

## 2026-07-04 — continuation (README + gh description)

> Also when you finish, edit the readme and the gh description to reflect the new reality of vpn bypass

## 2026-07-04 — continuation (hardening backlog)

> [pointing at the deferred hardening milestone — audit-token XPC fix, timeout→orphaned-route
> kernel reconcile, apply-head + DNS-engine unification, classic-mode compiler extraction +
> apply-path integration tests, helper addRoutesBatch parallelization, DNS concurrency cap, and
> the god-class split — recorded in docs/CODE-REVIEW-3.0.1.md]
>
> /sergio-loop over it too when you finish with all this

## 2026-07-04 — continuation (3.1.0 loop, after shipping 3.0.1)

> Just kill the runner if its so problematic, i just want it purely free or if not i just take care of the releases
> fix this and /sergio-loop towards 3.1.0 with a new PR asap

**Context:** 3.0.1 shipped (PR #55 merged; release v3.0.1 + cask, all on FREE macos-latest CI after
moving off the dead self-hosted runner, which was killed). Now: new PR `feat/routemanager-3.1.0`, loop to
3.1.0 = the **audit-token XPC** hardening (the `feat:` that makes it a minor; explained to Sergio: replaces
the PID-reuse-vulnerable caller check with the kernel audit token; anti-brick fallback; needs ONE
admin-install live-test on his Mac) + the **god-class split** (US-013). Delicately; classic routing stays
byte-identical.

## 2026-07-04 — continuation (3.2.0, self-release)

> over it and release it directly dont ask me just unblock yourselph, use ralph

## 2026-07-18 — continuation (issue #61 — strand-on-preemption leak)

> /research! and then /sergio-loop over it with ralph in workflows

_Topic ("it") = GitHub issue **#61**: a VPN-Only leak where an apply preempted mid-kernel-add
strands untracked routes. `applyAllRoutesInternal` → `commitAppliedRoutes` adds routes to the
kernel (`addRoutesBatch`) BEFORE recording them in `activeRoutes` (recorded only after
`guard routeEpoch == epoch`, `RouteManager.swift:1752`); `removeAllRoutes()` (`:1499`) removes
ONLY tracked `activeRoutes` and bumps `routeEpoch`. A disconnect/config-change `removeAllRoutes()`
interleaving at an `await` after the kernel add but before the commit removes nothing and the
apply aborts → kernel routes stranded, untracked = silent VPN-Only leak. Systemic across every
apply path (callers don't uniformly hold the route-operation gate)._

**Done =** correct minimal fix across ALL apply paths (no untracked strand when a teardown
interleaves any apply); classic Bypass/VPN-Only route SETs byte-identical; helper stays
ad-hoc-signable (no NE entitlements); no brick; teardown stays prompt (no deadlock/latency
regression). Verified: `swift build` + full tests + NEW interleave-reproducing regression test +
universal helper build + Mac-mini. Open a **PR** with CodeRabbit addressed — **do NOT merge
without Sergio's explicit approval.** Loop: `/research! → /implement! → /review-pr!`, ralph
persistence, then `/oh-my-claudecode:cancel`.
