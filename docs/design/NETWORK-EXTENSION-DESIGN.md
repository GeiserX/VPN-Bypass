# Network Extension engine: design

Status: planned, nothing built. Written 2026-10-30, the day the "no Network Extension entitlements" rule
(`docs/MULTI-ROUTE-DESIGN.md`, the 2026-07-03 hard constraint) was lifted.

Words used here:
- **NE:** Apple's Network Extension framework.
- **Transparent proxy:** an `NETransparentProxyProvider`. macOS offers it each new outbound TCP or UDP
  connection (a **flow**) that matches its include rules. It either takes the flow and carries the bytes
  itself, or returns `false` and the flow continues as if the proxy were not there.
- **System extension (sysext):** the separate bundle, inside the app, that runs the provider as root.
- **Kernel engine:** what ships today: host routes via the physical gateway, `/etc/hosts`, the wildcard
  forwarder, loopback proxy listeners.

## 1. The problem

The kernel engine routes by destination IP. Three things are out of its reach:

- **"This app never uses the VPN."** A routing table has no idea which app sent a packet. The `process`
  rule type exists in the model (`Sources/VPNBypassCore/RouteModel.swift:43`) and is accepted by `vpnb`
  (`CommandRouter.swift:392`), but nothing acts on it: `RuleResolver.swift:29,45`,
  `RuleDestinationBuilder.swift:73,99` and `WildcardRoutes.swift:90` all skip it. Today a process rule is a
  silent no-op. Users asked for per-app routing in #2 (Discord voice), #184 and #186. #2 is UDP, so
  the TCP-only v1 does not fix it; it needs the UDP stage (3.6).
- **Proxy routes for apps that ignore `HTTPS_PROXY`.** A kernel route cannot point at a loopback listener,
  so proxy and Tailscale-peer routes reach only apps that opt in through the env, the `route-on` hook or
  the PAC (`RouteCompiler.swift:94-95`, `docs/MULTI-ROUTE-DESIGN.md:303-310`).
- **Names that share an IP.** The packet carries no hostname, so names on a shared CDN IP follow each
  other (`docs/research/wildcards-and-network-extension.md`, table of limits).

## 2. Decision

**Engine:** an opt-in `NETransparentProxyProvider`, shipped as a Developer ID system extension inside
`VPN Bypass.app`. Why this provider and no other:
- It is the only NE provider where returning `false` hands the flow back to normal routing. Apple:
  returning NO "causes the flow to proceed to communicate directly with the flow's ultimate destination"
  (`NETransparentProxyProvider.h:23`). The app-proxy and DNS-proxy providers discard a declined flow.
- Apple names it for this job. TN3120: "Do not use a packet tunnel provider to selectively claim traffic
  ... The recommended alternative is to implement a NETransparentProxyProvider on macOS."
- No MDM and no App Store needed (TN3134). It needs two user approvals.
- A packet tunnel is out anyway: only one enterprise VPN configuration can be enabled at a time, and
  Tailscale holds that slot on the test Mac.
- Content filters, URL filters and the DNS proxy cannot route.

**What ships first:** per-app bypass. A `process` rule (Custom mode) or an app in a new Bypass-mode
"Apps" list sends that app's **TCP** flows out the physical interface, past the VPN. Why this first:
- The kernel engine cannot do it at all.
- It fails safe. If the extension is off, dead or unapproved, the app's traffic simply stays in the VPN.
  Nothing leaks.
- It writes no kernel routes, so it adds nothing to the route churn that has troubled GlobalProtect
  before (#65, #106).
- It needs no new DNS machinery. The cost of that: a bypassed app still resolves through the VPN's DNS,
  so the VPN's resolver sees the names it looks up, and a CDN may hand it an address for the VPN's
  region rather than the user's.
- Interface scoping is the egress the proxy listeners already use beside GlobalProtect
  (`parameters.requiredInterface = interface`, `ProxyForwarder.swift:746`). The extension reaches it
  through the C Network API instead, because it must also carry the flow's metadata (3.5).

**What stays on kernel routes:** everything that works today, in every mode. Domains, services, IPs,
CIDRs, wildcards, VPN Only, multi-VPN, the helper, `/etc/hosts`, the forwarder. The kernel engine stays
the default and the fallback, for three reasons:
- Some Macs will never allow the extension (MDM sets `AllowUserOverrides=false`).
- Some users will never click the two approvals.
- Every byte the extension claims is copied through user space twice. Kernel routes cost nothing per byte.

**Later, in order:** proxy and Tailscale-peer routes for any app; UDP; hostname correctness for
connect-by-name flows; per-app VPN-only last, because it fails open (if the extension dies, that app goes
direct).

**Not planned:** a DNS proxy (GlobalProtect declares one, the forwarder already covers wildcards), a
content filter, a packet tunnel, TLS interception.

## 3. Architecture

### 3.1 Bundles

```
VPN Bypass.app/Contents/
  MacOS/VPNBypass                       app: owns NETransparentProxyManager, sends the policy
  MacOS/vpnb                            unchanged, no entitlements
  MacOS/com.geiserx.vpnbypass.helper    unchanged, no entitlements
  Library/LaunchDaemons/...helper.plist unchanged
  Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension/
    Contents/Info.plist                 CFBundlePackageType SYSX, NetworkExtension dict
    Contents/MacOS/com.geiserx.vpn-bypass.proxy
    Contents/embedded.provisionprofile
  embedded.provisionprofile             the app's profile
```

- Extension id: `com.geiserx.vpn-bypass.proxy`.
- Extension `Info.plist`: `NSSystemExtensionUsageDescription`, `LSMinimumSystemVersion` 15.0, and
  `NetworkExtension = { NEProviderClasses = { com.apple.networkextension.app-proxy = FlowProxy } }`.
  The class is declared `@objc(FlowProxy)`, so its Objective-C runtime name is `FlowProxy` whatever the
  SwiftPM module is called, and the plist value is that bare name (not `<Module>.FlowProxy`). CI checks
  that the plist value names a class in the built binary (`otool -ov` or `nm` on the ObjC class list),
  because a mismatch would only show at activation.
- No app group and no `NEMachServiceName`. The shipping mitmproxy redirector runs without either (its
  extension `Info.plist` has only `NEProviderClasses`). If activation on macOS 27 rejects that, add the
  app group `624WUVM8B4.com.geiserx.vpn-bypass` as `NEMachServiceName`; another app proxy on the test
  Mac runs with that layout.
- The extension's `main.swift` is `autoreleasepool { NEProvider.startSystemExtensionMode() }; dispatchMain()`.

**macOS floor.** The app stays at macOS 13 (`Package.swift:8`). The engine needs macOS 15: that is where the
`nw_endpoint_t` flow APIs replaced the deprecated `NWHostEndpoint` ones, and supporting both doubles the
flow code. On 13 and 14 the engine reports `unavailable` and never submits an activation request.

### 3.2 Entitlements, per binary

| Binary | Entitlements | Profile |
|---|---|---|
| `VPNBypass` (app) | `com.apple.developer.system-extension.install = true`; `com.apple.developer.networking.networkextension = [app-proxy-provider-systemextension]` (needed to save the proxy configuration) | `MAC_APP_DIRECT` for `com.geiserx.vpn-bypass` |
| Extension | `com.apple.developer.networking.networkextension = [app-proxy-provider-systemextension]` | `MAC_APP_DIRECT` for `com.geiserx.vpn-bypass.proxy` |
| `vpnb`, helper | none (as today) | none |

Rules learned from earlier AMFI incidents on another app:
- On macOS 26 and later, AMFI SIGKILLs a binary that carries these restricted entitlements without an
  embedded matching profile, even when it is notarized. The profile file must be named
  `embedded.provisionprofile`.
- The certificate inside each profile must be the signing certificate: `LTV59DZ9B4`, Developer ID
  Application G2, SHA-1 `0709E698...`, expires 2031-09-17.
- Never combine the NE entitlements with `cs.disable-library-validation` or
  `cs.allow-unsigned-executable-memory` on one binary. Only `cs.allow-jit` is allowed beside them. The
  app has no runtime relaxations today, so nothing conflicts.
- The helper authorizes the app by identifier and team (`scripts/sign-and-notarize.sh:34`). Entitlements
  and a profile do not change that requirement.

**The one real packaging risk.** With the entitlements on the main app, a bad or missing profile kills the
whole app at launch, including the kernel engine everyone relies on. We accept that because one app is
simpler than a separate activator app plus IPC between them, but only behind a release gate that is proven
to go red (section 6.3). If no runner can make that gate fail, the fallback is a nested activator app
(PIA's layout: a sub-app inside the bundle that owns the extension and the entitlements), so the main
binary never carries them.

### 3.3 Config delivery

- **Never use `providerConfiguration`.** `/Library/Preferences/com.apple.networkextension.plist` is
  `-rw-r--r-- root wheel` on the test Mac and holds other vendors' provider settings in clear text.
  Anything we put there is readable by every local user.
- **Use `sendProviderMessage`** on the manager's session, handled by `handleAppMessage` in the extension.
  The message is a versioned `FlowPolicy` blob:
  - generation number;
  - ordered matchers: for v1 only process matchers (bundle id or executable name) and the rule id;
  - per-rule egress: `direct(interface)`, later `vpn(utun)` and `proxy(port)`;
  - the physical interface name from `RouteManager.detectPhysicalInterface()` (`RouteManager.swift:5291`),
    the same one the proxy listeners bind to (`RouteManager.swift:5208-5218`). The test Mac is dual-homed
    (en0 and en8), so "en0" must never be hard-coded;
  - a lease length.
- **Lease.** Same idea as the helper's wildcard lease (`HelperProtocol.swift:113-115`). Without a fresh
  policy within the lease (2 minutes), the extension declines every flow. That is exactly today's
  behaviour, so a quit or crashed app can never leave stale per-app routing behind. A menu bar app
  that sits idle can have its timers delayed by App Nap and timer coalescing, so `FlowEngineManager`
  holds a `ProcessInfo` activity while the engine is on, the heartbeat runs every 30 s (a quarter of
  the lease), and the extension counts lease expiries in the status counters so a lapse is visible.
- **Unknown policy version.** An extension that receives a policy version it does not know (a new app
  talking to an old extension whose replacement is still pending, 6.4) treats it as no policy and
  declines every flow, and reports the mismatch in the heartbeat reply.
- **When the app pushes:** on every rule or mode change (`commitAppliedRoutes`, `RouteManager.swift:2872`),
  on a network or VPN change (same moment the listeners re-bind, `reconcileProxyListeners`,
  `RouteManager.swift:5208`), when the extension reports it (re)started (the manager's status turns
  `connected`), and on a heartbeat inside the lease.
- **Include rules never change at runtime.** They are set once in `startProxy` and cover all outbound TCP
  minus fixed exclusions (3.4). Every decision lives in the policy message. That way a rule change never
  needs `setTunnelNetworkSettings`, a re-save of the manager, or a restart, any of which may close flows
  (risk R1).
- The manager is saved only when its static fields really changed. PIA saw consent lost on re-save
  (pia-foss/desktop#94).

### 3.4 Flow matching

`NENetworkRule` can match only remote address, port, protocol and direction, never the app. So per-app
routing must include broadly and decide per flow.

`includedNetworkRules`: one rule, `remoteNetwork nil`, protocol TCP, outbound. (`nil` matches every remote
except loopback, `NENetworkRule.h:116-122`.)

`excludedNetworkRules` (fixed): 10/8, 172.16/12, 192.168/16, 169.254/16, 224/4, 100.64/10 (Tailscale,
`ProtectedDestinations`, `HelperProtocol.swift:325-331`), fc00::/7, fe80::/10, ff00::/8, fd7a:115c:a1e0::/48.
Apple says exclusions win, but FB14453214 reports them ignored, so `handleNewFlow` repeats the checks.

What "include all TCP" means for R1: every TCP flow on the Mac matches the include rule, including the
VPN client's own TCP connections (GlobalProtect's portal, HIP reports and its SSL fallback tunnel). The
verdict in `handleNewFlow` declines them, but a start or stop of the proxy acts on matching flows
before any verdict (3.7). So under the narrow reading of "a start closes matching flows", the VPN's
TCP is still in scope. We do not add the VPN gateway's address to the exclusions in v1: it changes
when the client picks another gateway, and every change would need `setTunnelNetworkSettings`, which
may itself close flows. L1 decides whether that trade is worth revisiting.

`handleNewFlow` is synchronous and must never block: no DNS, no I/O, no XPC. It reads one in-memory
table:
1. No live policy (none yet, or lease expired): return `false`.
2. Flow from our own app, helper or extension, from a VPN or security client, or from `mDNSResponder`,
   captive-portal or Apple push daemons: return `false`. VPN and security clients are recognised by
   **team identifier**, not by signing id: GlobalProtect's daemon is signed `Identifier=PanGPS`,
   `TeamIdentifier=PXPZ95SK77`, so a `com.paloaltonetworks.*` prefix would never match it.
   `NEFlowMetaData` carries no team id, so the extension reads it from `sourceAppAuditToken`
   (`SecCodeCopyGuestWithAttributes` with the audit token, then `SecCodeCopySigningInformation`),
   cached per audit token. The list of declined teams (Palo Alto `PXPZ95SK77` and the other VPN vendors
   the app already detects) lives in the pure `FlowDecider`, so it is unit-tested. `ruleAdd` and the
   app chooser refuse a process rule whose bundle id or basename belongs to a declined team's app.
3. `flow.isBound` is true (the app bound its own socket to an interface): return `false`.
4. Match `metaData.sourceAppSigningIdentifier` against process matchers:
   - a bundle id matches exactly or on a dot boundary (`com.google.Chrome` covers
     `com.google.Chrome.helper`, but not `com.google.ChromeX`), unlike PIA's bare prefix;
   - otherwise an executable basename matches the path from `sourceAppAuditToken` (pid, then
     `proc_pidpath`), cached per audit token with eviction.
5. No match, or the matched rule's route is the VPN default: return `false`.
6. IPv6 destination in v1: return `false` (the app is IPv4-only, `RouteKernel.swift:312`, and IPv6
   egress on the physical interface is a live question). The flow stays in the VPN.
7. Otherwise claim it (return `true`) and re-emit (3.5).

`remoteHostname` is not used for matching in v1. It is set only for connect-by-name callers
(URLSession, Network.framework); Chrome, curl and Go arrive as bare IPs.

### 3.5 Re-emit path

For a claimed flow, in this order (the order matters):
1. Build an `nw_parameters_t` with the C Network API: `nw_parameters_create_secure_tcp` with TLS
   disabled and, in the TCP configure block, no-delay on and a 5 s connect timeout; then
   `nw_parameters_require_interface` with the `nw_interface_t` of the policy's physical interface.
   Interface scoping beats the routing table for a routes-only tunnel (Apple, "Routing your VPN network
   traffic"; XNU `ip_output.c` `IP_BOUND_IF`), and the test Mac has the scoped defaults this needs
   (`default UGScIg en0` and `en8`). Do not copy PIA's source-IP bind: it moves zero bytes behind a
   VPN's `0/1` routes on macOS 26.3 (pia-foss/desktop#93).
2. Call `flow.setMetadata(params)`. It writes the flow's `NEFlowMetaData` into those parameters, and
   only a connection created from them afterwards carries it, so any later transparent proxy sees the
   original app instead of our extension (`NEAppProxyFlow.h`, `setMetadata:`). Calling it after the
   connection exists does nothing.
3. `nw_connection_create(endpoint, params)`. The Swift `NWParameters`/`NWConnection` API cannot be used
   for this egress: it has no public way to wrap an `nw_parameters_t`, so it cannot carry the metadata.
   A BSD socket with `IP_BOUND_IF` (Proton's way) cannot carry it either.
4. The endpoint is the flow's `remoteFlowEndpoint`. For a connect-by-name flow that is host:port: dial
   the name with the same scoped parameters, so it resolves on the physical interface. The name is held
   in memory for that connection only, never logged or stored (3.8).
5. When the connection is ready, `flow.open`, then copy both ways with a bounded buffer per direction
   (Apple warns that unbounded buffering gets the provider jetsam-killed).
6. If the connect fails, close the flow with an error. A claimed flow cannot be handed back.
7. A connection that sat claimed but idle stays open; no read timeouts (Proton tears idle flows down after
   3 s, which breaks long-lived connections).

### 3.6 UDP

Not in v1. Two reasons:
- Chromium QUIC breaks on a flow-diverted UDP socket: `IP_DONTFRAG` and `IP_RECVTOS` fail with ECONNRESET
  and Chrome aborts QUIC (FB23636906, still open on macOS 26 and 27). The divert happens at `connect()`,
  before our verdict, so including UDP 443 broadly probably costs every Chrome user QUIC even for flows
  we decline.
- UDP needs one upstream per remote endpoint per flow, a different copier.

UDP (Discord voice, Zoom media, #2) comes in its own stage, after live test L7 says what including UDP
does to apps we decline. Under a proxy route, UDP flows are closed so the app falls back to TCP; HTTP
CONNECT cannot carry UDP.

### 3.7 Failure behaviour: a crash must never break the VPN session

The VPN client's own flows are never claimed: they are declined by team identifier (3.4 step 2), and
no process matcher can name them. That protects them from our verdict, not from the moments the OS
itself acts on flows, which come before any verdict.

- **Start, stop and restart.** Apple: "Starting a transparent proxy should close all flows"
  (forums thread 827831). We do not know yet whether "all" means only matching flows or every flow on the
  Mac. Either way it covers the VPN client's TCP, because the include rule matches all outbound TCP (3.4).
  So while a VPN is connected the start warning stays, whatever L1 shows about non-matching flows.
- **Starts and stops the app makes.** The app controls only these: turning the engine on or off,
  saving the manager, filing an activation or replacement request, and the watchdog's automatic stops
  below. Rules for them:
  - an on or off by the user, with a VPN connected, shows the warning ("turning this on may reset open
    connections, including the VPN's");
  - the app never starts the engine by itself while a VPN is connected: not at app launch, not after an
    update, not as crash recovery;
  - rule changes never restart it (3.3);
  - the watchdog's automatic disables (below) are stops while a VPN may be connected. They are taken
    only when the extension is already failing every new connection, where the stop is the lesser harm.
- **Starts and stops the OS makes on its own.** Once the configuration is enabled, `nesessionmanager`
  starts the provider again without asking us: at boot or login (often while GlobalProtect is
  auto-connecting), after a provider crash, after sleep and wake, and when `sysextd` replaces or
  removes the extension (6.4). The only lever we have is `isEnabled = false` on the configuration,
  which stops those restarts and is itself a stop. Live tests L1, L8, L9 and L11 cover these with a VPN
  connected.
- **If L1 shows the VPN's sockets are closed by a start**, the only safe v1 is one where the
  configuration does not stay enabled across reboots: the user turns the engine on per session, and
  the app sets `isEnabled = false` when it quits and at logout. Otherwise R1 becomes an accepted risk,
  written down as such. If L1 shows they are not closed, the app may keep the configuration enabled.
- **Crash.** Flows the extension was copying die; those are only the per-app flows. New flows: undocumented
  (direct, stalled or failed; live test L8). The OS restarts the provider by itself (above). The app
  watches the extension with a ping inside the lease heartbeat:
  - extension restarted by the OS: re-push the policy, show a notice;
  - extension silent while new connections stall (L8 decides how we detect it): disable the
    configuration, notify, fall back to kernel routes. A Mac whose every new connection hangs is already
    broken, so the stop is the lesser harm;
  - three crashes in 10 minutes: disable and say so, the same strike idea as the apply kill.
- **App quits or crashes.** The lease runs out and the extension declines everything. Per-app flows then
  go into the VPN, which is safe.
- **Another VPN with `includeAllNetworks` or `enforceRoutes`.** Interface scoping cannot escape it
  (Apple: `enforceRoutes` "supersedes the system routing table and scoping operations by apps"). The
  engine stops claiming (policy push with no matchers) and says why. The engine reads the flags itself
  from the NE preferences (`includeAllNetworks` and `enforceRoutes` of the enabled VPN configurations)
  and does not wait on the kill-switch warning (#186), which detects a kill switch by behaviour and is
  written for kernel routes. Once that warning is merged, the engine also stands down on its detection
  (stage 6).
- **Kill switch for us.** A menu item "Pause per-app routing" pushes an empty policy (no restart, no
  flows closed). Pause is not an off switch: the include rule stays installed, so every new TCP
  connection on the Mac still goes through a synchronous call into the extension and a hang would still
  stall it (R8). The UI copy says so. Only "Turn off" (`isEnabled = false`, closes flows, warned)
  removes that call.

### 3.8 Logging and privacy

The extension sees app identities, destination IPs and sometimes hostnames. It must never log or persist
any of them, not even as `%{private}`.
- The extension logs through one function that takes a fixed `enum Event` and integers only. A string
  cannot be passed, so a hostname cannot reach the log by accident.
- Counters only: flows claimed, declined, failed, per rule id. They travel back in the heartbeat reply.
- Nothing is written to disk by the extension.
- `remoteHostname` is read nowhere in v1. When hostname rules arrive, it is compared in memory and dropped.
- The app's existing rule stands: Lookups is opt-in and no hostname is logged.

## 4. Integration with the existing code

New code shape:
- `Sources/VPNBypassPolicy/` (new target, pure, no resources): `FlowPolicy` (Codable), `FlowPolicyCompiler`
  (app side: config to policy) and `FlowDecider` (extension side: flow facts to verdict). Unit-tested like
  `RuleResolver` and `RouteCompiler`.
- `Sources/VPNBypassProxy/` (new executable target): the provider. It links `VPNBypassPolicy` and
  NetworkExtension only. It must not link `VPNBypassCore`: that target has resources, and its
  `Bundle.module` accessor would trap inside the extension.
- `Sources/VPNBypassCore/FlowEngineManager.swift` (new, `@MainActor`): activation request,
  manager save, policy push, heartbeat, state machine.

Touch points, by file:
- `RouteModel.swift:43`: keep `case process`; drop the "P3, NE-only" comment for a real definition of the
  pattern (bundle id or executable basename).
- `CommandRouter.swift:392` `ruleAdd`: validate a process pattern (bundle-id shape or a bare basename,
  no path, no wildcard).
- `RuleResolver.swift:29,45`, `RuleDestinationBuilder.swift:18,73,99`, `WildcardRoutes.swift:90`: no
  change. Process rules stay invisible to the kernel engine; the extension serves them.
- `ConfigModel.swift:187` `derive`: the Bypass-mode "Apps" list derives to process rules with the Direct
  route, the same way the domain list derives to domain rules. Add `bypassApps: [String]` and
  `flowEngine: { enabled: Bool }` with `decodeIfPresent`; old builds ignore both, no `schemaVersion` bump
  (same pattern as `RouteModel.swift:46-52`).
- `RouteManager.swift:2872` `commitAppliedRoutes` and `:5208` `reconcileProxyListeners`: call
  `FlowEngineManager.pushPolicy()`.
- `RouteManager.swift:2034` `refuseVPNOnlyUnderGlobalProtect`: unchanged. VPN Only stays kernel-only.
- `ControlSurface.swift:86-95` and `CommandRouter.swift:107` `RuntimeStatus`: add `flowEngine` with the
  state, policy generation and per-rule counters. No names, no IPs.
- `CommandRouter.swift:243` `isMutating`: add `engine.on` and `engine.off`. New read verb `engine.status`.
  `engine.on` can only file the activation request; the reply says approval is waiting in System Settings.
  All additive, so the envelope `v` is not bumped.
- `SanitizedRule` gains `servedBy: kernel | flow | inactive`.
- `RulesTab.swift:1082-1085`: add PROCESS to the picker, with an app chooser (bundle ids from
  /Applications) plus free text. `RulesTab.swift:800` already has the badge.
- vpn-bypass-mcp (separate repo): pass the new status fields through; add `engine_status` (read) and
  `engine_on`/`engine_off` (destructive).

Modes:
- **Bypass:** the new "Apps" list. Listed apps go direct.
- **Custom:** process rules with a Direct route in v1; VPN-pinned and proxy routes in later stages.
- **VPN Only:** no per-app in any planned stage.

The helper does not change. The extension never writes routes; one privileged route writer stays simpler.

## 5. Opt-in UX and fallbacks

**Settings > General, "Per-app routing" card**, off by default. Before any system prompt it says:
- what it does: only apps you list skip the VPN;
- macOS will ask twice: first allow the extension in System Settings > General > Login Items &
  Extensions > Network Extensions, then "VPN Bypass would like to add proxy configurations";
- if you say no, nothing else changes.

**States** shown in the card, the menu and `vpnb status`:

| State | Meaning | Process rules show |
|---|---|---|
| `unavailable` | macOS below 15, or a build without the entitlements (dev and CI) | "needs macOS 15" or "not in this build" |
| `off` | user has not turned it on | "inactive: per-app routing is off" |
| `awaitingExtensionApproval` | request filed, user has not allowed it | "waiting for approval" plus the System Settings path |
| `awaitingConfigApproval` | extension allowed, proxy configuration prompt pending | same |
| `blocked` | MDM forbids it, or the app is not in /Applications | the reason; stop asking |
| `starting` | | |
| `active` | | "served by per-app routing" |
| `paused` | empty policy pushed by the user | "paused" |
| `failed` | crash strikes, or a VPN kill switch detected | the reason |

In every state except `active`, the kernel engine runs exactly as today. No process rule is ever a silent
no-op again.

**Remove.** An in-app "Remove per-app routing" does `removeFromPreferences`, then a deactivation
request. Homebrew cannot do it: a cask cannot launch the app. We expect `brew uninstall` to leave the
extension active until reboot, but nobody has tested it; live test L9 checks it. The troubleshooting doc gets a "remove the extension" entry with
`systemextensionsctl` steps.

## 6. Packaging, CI and the cask

### 6.1 Build (no Xcode project)

- `Package.swift`: targets `VPNBypassPolicy` and `VPNBypassProxy` (product `com.geiserx.vpn-bypass.proxy`).
  The universal `swift build --arch arm64 --arch x86_64` already builds every product (`Makefile:13`).
- `Makefile` `bundle` (`:53`): copy the binary and `Proxy/Info.plist` into
  `Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension/`. Stamp
  `CFBundleShortVersionString` and `CFBundleVersion` like the app's. macOS replaces the extension only
  when its version changes.
- The extension bundle carries the app icon too (`Contents/Resources/AppIcon.icns`, `CFBundleIconFile`
  `AppIcon` in `Proxy/Info.plist`). Without an icon, the approval alert and System Settings show a
  blank white one; the spike did until 0.1.5.
- `make run` opens the app from the repo, where activation fails ("must be in /Applications"). Only
  `make install` builds can activate. Dev builds are unsigned and report `unavailable`.

### 6.2 Signing (`scripts/sign-and-notarize.sh`, mode `app`, `:51-58`)

Inside out:
1. helper and `vpnb` as today;
2. copy the extension profile to `<ext>/Contents/embedded.provisionprofile`, sign the extension with
   `--entitlements entitlements/proxy.entitlements`;
3. copy the app profile to `Contents/embedded.provisionprofile`, sign the app with
   `--entitlements entitlements/app.entitlements`;
4. verify: `--verify --deep --strict`, the helper requirement, `codesign -d --entitlements -` on both, and
   `security cms -D` on both profiles: certificate SHA-1 equals the signing identity's,
   `application-identifier` is `624WUVM8B4.<id>`, profile entitlements are a superset of the signed ones,
   not expired;
5. notarize and staple as today. The nested extension is covered by the app's ticket.

`VPNBypass.entitlements` is unused today except as an auto-tag path filter; replace it with the
`entitlements/` directory.

### 6.3 CI and release

- `release.yml`: two secrets, `PROVISIONING_PROFILE_APP_BASE64` and `PROVISIONING_PROFILE_PROXY_BASE64`,
  decoded into `$RUNNER_TEMP`. Missing secret fails the release (no fallback, as today at `:125-127`).
- **Launch gate.** Today `release.yml` never launches the signed app. Add a step on `runs-on: macos-26`
  that runs `scripts/smoke-launch.sh` on the stapled app and fails if it dies in the first seconds.
  Prove the gate can go red once with a deliberately wrong profile. If the runner does not enforce AMFI,
  the gate is worthless and section 3.2's fallback (nested activator) applies.
- `ci.yml`: add the extension binary to the universal-architecture loop (`:98-107`); assert its
  `Info.plist` has `SYSX` and `NetworkExtension`, and that its `NEProviderClasses` value is an ObjC
  class in the built binary. CI bundles stay unsigned and entitlement-free.
- `auto-tag.yml:22-31`: add `entitlements/**` and `scripts/**` to the paths.
- `.gitignore`: add `*.provisionprofile`. Profiles and keys never enter git.

### 6.4 Cask

No change to the stanzas. `app` installs to /Applications. A user with `--appdir=~/Applications` gets
`unsupportedParentBundleLocation`; the engine shows `blocked` with that reason and the kernel engine
keeps working. No preflight or postflight (`release.yml:277-287` already forbids them). The app relaunches
itself after an update (`AppUpdateRelauncher.swift`) and resubmits the activation request; the delegate
answers `.replace` when the version differs. That replacement is a restart of the extension, so the
app defers it until the VPN disconnects or the user agrees (3.7).

That deferral is unproven, and part of the update is not ours to defer. Homebrew removes the old bundle
and then moves the new one in (`AppUpdateRelauncher.swift` names the `missing` state in between).
`sysextd` may treat the containing app as removed and stop or uninstall the running extension before
our app runs again, which would be a stop while the VPN is up. Live test L9 answers it with a real
`brew upgrade` and an in-place bundle swap. Until it does, the doc claims no deferral works.

For a user whose VPN is always on, "defer until the VPN disconnects" can mean never. A new app then
talks to an old extension: the policy carries a version, and an extension that does not know it
declines every flow (3.3), so per-app routing stops and the card says an update of the extension is
waiting, with a button that replaces it now (warned).

## 7. App Store Connect steps (run later, idempotent)

Key: the team's App Manager API key (kept outside the repo). A probe
`POST /v1/profiles` with a bogus bundle id returned 409, not 403, so the key likely may create profiles;
if not, the Account Holder does steps 1-3 on the portal.

1. `POST /v1/bundleIds` for `com.geiserx.vpn-bypass` and `com.geiserx.vpn-bypass.proxy`, platform
   `MAC_OS`. Neither exists today (16 ids, all `UNIVERSAL`).
2. `POST /v1/bundleIdCapabilities`: app `SYSTEM_EXTENSION_INSTALL` and `NETWORK_EXTENSIONS`; extension
   `NETWORK_EXTENSIONS`. Read the current capabilities first and post only missing ones: re-posting an
   enabled capability turns existing profiles INVALID.
3. `POST /v1/profiles`, `profileType MAC_APP_DIRECT`, certificate `LTV59DZ9B4`, one per bundle id, no
   devices.
4. Check `profileState == ACTIVE`, decode `profileContent`, confirm the certificate SHA-1 and that the NE
   values carry the `-systemextension` suffix.
5. Store both as GitHub secrets. Keep a local copy outside the repo for signing on the MacBook.

Sign only with team 624WUVM8B4. The profile-minting script gets a `--dry-run` mode and lives outside
the release path.

## 8. Test plan

### 8.1 Unit (Mac mini, `swift test`)

- `FlowDecider`: no policy declines; expired lease declines; unknown policy version declines; self,
  system daemons and VPN clients decline (VPN clients by team id, with a bare-identifier case such as
  `PanGPS` under team `PXPZ95SK77`);
  `isBound` declines; bundle-id dot-boundary match (positive `com.x.App.helper`, negative `com.x.AppX`);
  basename match; IPv6 declines; VPN-default route declines; Direct claims.
- `FlowPolicyCompiler`: Bypass "Apps" and Custom process rules compile to the same matchers; rule order
  kept; no hostname or credential ends up in the blob (assert on the encoded bytes).
- `ruleAdd` validation: accepts bundle ids and basenames, rejects paths, wildcards and declined-team
  apps.
- Logging: a compile-time check that the extension's log function takes no `String`.
- Each new test is first run against a deliberately broken decider and must fail.

### 8.2 Mac mini (no GlobalProtect): the first live tests

The mini has SIP disabled and no personal signing identity. It cannot test AMFI (L0), because AMFI is
not enforced there. It can test activation: with SIP off, `systemextensionsctl developer on` lets it
activate a build signed on the MacBook and copied over. So the riskiest questions are answered there
first, where a dropped VPN costs nothing:
- builds, unit tests, bundle layout checks, and an iperf3 server for L10;
- **stage 4b:** copy the signed spike build, turn on sysext developer mode, bring up a throwaway
  WireGuard tunnel, and keep a long `ssh` session and a long TCP download running through it and
  outside it. Run L1, L8, L9 and L11 there (8.3 says how).

Go to the MacBook only if the mini shows that flows outside the include rule survive a start and a
stop. L0 stays on the MacBook, where AMFI is enforced.

### 8.3 Live tests: the mini first (L1, L8, L9, L11), then the MacBook with GlobalProtect connected

Hard rules for every step: never restart, reconnect or reconfigure GlobalProtect or any VPN; watch only.
Read GlobalProtect's logs (`PanGPS.log`, `pan_gp_event.log`) for `Broken pipe` and ProcDrv quit before,
during and after each step. If GlobalProtect drops at any point, stop, turn the engine off and write down
the timestamps.

**The owner's approval steps** (only the owner does these; the agent never activates anything):
1. Install the signed spike build to /Applications (`make install` with the release signing step).
2. In the app, Settings > General > Per-app routing > Turn on. macOS shows "System Extension Blocked".
3. Open System Settings > General > Login Items & Extensions > Network Extensions, switch on
   "VPN Bypass", enter the admin password.
4. Back in the app, the "VPN Bypass would like to add proxy configurations" prompt appears. Click Allow.
5. Confirm with `systemextensionsctl list` (state `activated enabled`) and the card showing `active`.

Live questions, in this order. L1, L8, L9 and L11 run on the mini first (8.2), then again on the
MacBook. Do not move past L1 on the MacBook until the mini has answered it.

| # | Question | Positive control | Negative control |
|---|---|---|---|
| L0 | Does AMFI accept the hand-signed app and extension (no SIGKILL at launch)? | the release build launches | a build with the app profile removed is SIGKILLed (proves the check) |
| L1 | Does starting or stopping the engine close flows, and which? Two passes, both with an **empty policy**. Pass A: the include rule narrowed to one test destination (a host on the mini); a long TCP download to it matches, an `ssh` session elsewhere does not. Pass B: the v1 include-all-TCP rule, watching the VPN client's TCP (`lsof -i -P \| grep PanGPS` on the MacBook, the WireGuard peer's sessions on the mini) and its logs. Also a reboot or login with the configuration enabled while the VPN auto-connects | pass A: the download to the test destination is reset by the start (proves the start closes matching flows) | pass A: the `ssh` session outside the narrowed rule; both passes: the same sessions with the engine never touched over the same period |
| L2 | Does a claimed flow leave on the physical interface? One rule: a test binary only, never a browser. Check `tcpdump -i en0` vs `utun5`, and the public IP the flow sees | the bypassed binary sees the home IP | an unlisted `curl` sees the VPN's IP |
| L3 | Does GlobalProtect react (HIP report, enforcer, re-route) to scoped egress? | | engine paused: no GP log lines |
| L4 | Which signing id arrives for Safari (WebKit networking), Chrome helpers, `nsurlsessiond`, curl, an unsigned Go binary? Read through counters per rule, never by logging ids | | |
| L5 | With the owner's other transparent proxy enabled too: who sees flows first, and does `setMetadata` keep attribution? Run with both orders seen | | |
| L6 | Sleep and wake, Wi-Fi to Ethernet (en0 and en8): new flows still claimed and leaving on the new interface | | |
| L7 | UDP: does an include rule for UDP break Chrome QUIC for flows we decline? (gates the UDP stage) | | |
| L8 | `kill -9` of the extension: new matching flows go direct, stall or fail, and for how long? Does the OS restart it, and does that restart close the VPN's flows? | | |
| L9 | Version bump of the extension, by a real `brew upgrade` (remove, then move) and by an in-place bundle swap, with the engine active: does `sysextd` stop or uninstall the running extension when the old app goes (watch `systemextensionsctl list` and the VPN's logs), does the configuration stay enabled, is a new approval asked, are flows reset? Also `brew uninstall`: is the extension still active until reboot? | | |
| L10 | Throughput and CPU through the extension vs direct, iperf3 to the mini; added latency of new connections | | |
| L11 | Does the consent survive a reboot (PIA #94)? Does the OS start the provider at boot or login while the VPN connects, and does that close the VPN's flows? | | |
| L12 | A soak of 8 hours or more with GlobalProtect connected: drop count vs a baseline day with the engine off. GP logs are local time, ours UTC | | |

Before L1 is answered, every step uses one narrow rule. No browser rule before L4.

## 9. Risks

| # | Risk | Hard or impossible |
|---|---|---|
| R1 | Starting the proxy closes flows, and with include-all-TCP that covers the VPN client's TCP; if it also covers GlobalProtect's gateway socket, every start is a VPN drop and maybe a logout | **Hard**, partly not in our hands. The OS behaviour is fixed (Apple calls it deliberate, FB8969320 open). We control the starts we make: only on user action, warned (3.7). We do not control the OS's own restarts (boot, login, crash, extension replacement); the only lever is leaving the configuration disabled. L1, L8, L9 and L11, first on the mini, decide between a per-session engine and an accepted risk stated plainly |
| R2 | Order between several transparent proxies is unspecified without MDM; another proxy running after ours may re-route our flows into the tunnel | **Impossible to control** from our side without MDM's `Order` (an OS rule). Mitigation: `setMetadata` so attribution survives; detect and report via L5 |
| R3 | A VPN with `includeAllNetworks` or `enforceRoutes` | **Impossible** to escape: Apple says it supersedes scoping by apps, and `NETransparentProxyManager` cannot opt out. We stand down and say so |
| R4 | MDM sets `AllowUserOverrides=false` | **Impossible** on that Mac unless its admin allow-lists team 624WUVM8B4. Kernel engine stays |
| R5 | Bad profile kills the whole app at launch | **Hard.** Release launch gate proven red (6.3), or the nested activator |
| R6 | Chrome QUIC breaks on diverted UDP | **Hard**, an Apple bug (FB23636906). v1 is TCP-only; UDP waits on L7 |
| R7 | Resolve-then-connect apps give no hostname | **Hard.** Name rules for them keep using kernel routes and the forwarder |
| R8 | Extension hang stalls every new connection on the Mac, including while paused (the include rule stays installed) | **Hard.** Never block `handleNewFlow`; watchdog disables it (3.7); L8 measures. Only Turn off removes the exposure |
| R9 | Throughput loss through user space | **Hard.** Claim only listed apps' flows; L10 measures |
| R10 | Known Apple bugs with any transparent proxy installed: FaceTime/AirDrop, captive portals, flows lost after sleep | **Hard**, outside our code. Decline Apple daemons, pause on captive networks, document; L6 |
| R11 | Homebrew cannot remove the extension | **Hard.** In-app remove plus a documented manual path |

## 10. Staged plan (small PRs, each green)

Base branches. A merge to `main` that touches `Sources/**` (or the other paths in `auto-tag.yml`)
cuts a release by itself, so "releasable" is not enough: a stage must also be safe to ship to every
user the moment it merges.
- Stages 1 to 3 target `release/6.0` (no NE code, no entitlements).
- Stage 4 and later stay off `main` and out of 6.0.0 until the launch gate is proven red, unless they
  ship behind a build flag that leaves the entitlements and the extension out of the released bundle.
- Whether the engine itself gates the 6.0.0 release is the owner's call. This doc's size estimate
  (below) puts it weeks behind the rest of 6.0, so the default here is that 6.0.0 ships without it and
  the engine follows in a later minor release.

1. **This doc** and the lifted rule recorded in the old docs.
2. **Stop the silent no-op.** Process rules show "inactive: needs per-app routing"; `vpnb rule.add
   match=process` validates the pattern; `servedBy` in rule listings. No NE code.
3. **Pure policy.** `VPNBypassPolicy` with `FlowPolicy`, `FlowPolicyCompiler`, `FlowDecider` and their
   tests. No NE code.
4. **ASC and signing.** Register ids, add capabilities, mint profiles, store secrets (section 7). Signing
   script and release gate with entitlements on an app that still does nothing with them, plus an empty
   extension that declines every flow. Release gate proven red once. This is L0.
5. **Spike build** (not released): the extension with the TCP copier and the `FlowEngineManager`, one
   hard-coded test rule.
   - **4b, on the mini:** sysext developer mode, a throwaway WireGuard tunnel; run L1, L8, L9 and L11
     (8.2). Stop here if flows outside the include rule do not survive.
   - **On the MacBook:** the owner approves it; run L0 to L4, then L8, L9 and L11 again.
6. **Engine v1:** per-app bypass, TCP, Direct egress, Custom process rules. State machine, card,
   `vpnb engine.*`, status fields, watchdog, lease. Behind the opt-in. Depends on the kill-switch
   warning (#186) only for the extra stand-down signal (3.7); the engine reads the
   `includeAllNetworks`/`enforceRoutes` flags itself.
7. **Bypass-mode "Apps" list** and the app chooser.
8. **Remove path** and troubleshooting doc; MCP server tools (its own repo).
9. **Proxy and Tailscale-peer routes for any app:** relay claimed flows to the route's loopback listener
   with `CONNECT` plus the local secret. Needs `LoopbackPeerAuth` (`LoopbackPeerAuth.swift:15`) to accept
   the root extension, by mapping the peer port to a pid and checking the extension's code requirement.
   Credentials stay in the app.
10. **UDP**, if L7 allows it.
11. **VPN-pinned process rules**, then hostname rules for connect-by-name flows, each after its own live
    data.

Rough size, inferred: stages 2 to 4 a week; 5 and 6 three to four weeks; the rest a week or two each.

## Sources

- Apple: TN3134 https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- Apple: TN3120 https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers
- Apple: https://developer.apple.com/documentation/networkextension/netransparentproxyprovider
- Apple: https://developer.apple.com/documentation/networkextension/handling-flow-copying
- Apple: https://developer.apple.com/documentation/networkextension/nevpnprotocol/enforceroutes
- Apple: https://developer.apple.com/documentation/networkextension/nevpnprotocol/includeallnetworks
- Forums: flows closed on start https://developer.apple.com/forums/thread/827831
- Forums: order of transparent proxies https://developer.apple.com/forums/thread/820632
- Forums: hostnames only for connect-by-name https://developer.apple.com/forums/thread/770666
- Forums: Chrome QUIC on diverted UDP https://developer.apple.com/forums/thread/770707
- Forums: excluded rules ignored https://developer.apple.com/forums/thread/760232
- PIA split tunnel https://github.com/pia-foss/mac-split-tunnel and the source-IP bind issue
  https://github.com/pia-foss/desktop/issues/93
- Proton VPN macOS (Plutonium, `IP_BOUND_IF` re-emit) and mitmproxy_rs (minimal entitlements, MIT)
- SDK headers: `NETransparentProxyProvider.h`, `NETransparentProxyNetworkSettings.h`, `NENetworkRule.h`,
  `NEFlowMetaData.h`, `NEAppProxyFlow.h` (macOS 27.0 SDK)
- Earlier research: `docs/research/wildcards-and-network-extension.md`, section C
