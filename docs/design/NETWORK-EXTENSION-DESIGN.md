# Network Extension engine: design

Status: decided, not built. Written 2026-10-30, the day the "no Network Extension entitlements" rule
(`docs/MULTI-ROUTE-DESIGN.md`, the 2026-07-03 hard constraint) was lifted. Refreshed 2026-11-04 against
6.0.11 (helper 2.8.0) and the spike results (`spikes/ne-proxy/RESULTS-PART-A.md`,
`RESULTS-PART-B.md`).

Words used here:
- **NE:** Apple's Network Extension framework.
- **Transparent proxy:** an `NETransparentProxyProvider`. macOS offers it each new outbound TCP or UDP
  connection (a **flow**) that matches its include rules. It either takes the flow and carries the bytes
  itself, or returns `false` and the flow continues as if the proxy were not there.
- **System extension (sysext):** the separate bundle, inside the app, that runs the provider as root.
- **Kernel engine:** what ships today: host routes via the physical gateway, `/etc/hosts`, the wildcard
  forwarder and its resolver files, loopback proxy listeners. All of it through the root helper.
- **Per-app routing:** the user-facing name of the NE engine.

## 1. The problem

The kernel engine routes by destination IP. Three things are out of its reach:

- **"This app never uses the VPN."** A routing table has no idea which app sent a packet. The `process`
  rule type exists in the model (`Sources/VPNBypassCore/RouteModel.swift:43`) and `vpnb rule.add` accepts
  it with no check on the pattern (`CommandRouter.swift:409`), but nothing acts on it:
  `RuleResolver.swift:29,45`, `RuleDestinationBuilder.swift:73,99` and `WildcardRoutes.swift:92` all skip
  it. Today a process rule is a silent no-op. Users asked for per-app routing in #2 (Discord voice), #184
  and #186. #2 is UDP, so the TCP-only v1 does not fix it; it needs the UDP stage (3.6).
- **Proxy routes for apps that ignore `HTTPS_PROXY`.** A kernel route cannot point at a loopback listener,
  so proxy and Tailscale-peer routes reach only apps that opt in through the env, the `route-on` hook or
  the PAC (`RouteCompiler.swift:94-95`, `docs/MULTI-ROUTE-DESIGN.md:311-315`).
- **Names that share an IP.** The packet carries no hostname, so names on a shared CDN IP follow each
  other (`docs/research/wildcards-and-network-extension.md`, section 3).

## 2. Decision

**The owner's decision (2026-11-04): build it now, as an opt-in.** Per-app routing ships off by default.
The kernel engine stays the default for everyone and the fallback whenever the extension is off,
unapproved, failing or standing down. Turning per-app routing off is the old way: the app then behaves
as 6.0.x does. 6.1.0 ships the engine, after a live test on the owner's Mac. Until then every
stage after the honesty fix (section 10, step 2) lands on `release/6.1`, never on `main`.

**Engine:** an `NETransparentProxyProvider`, shipped as a Developer ID system extension inside
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

**What ships first:** per-app bypass. A `process` rule with the Direct route (Custom mode), or an app in
a new Bypass-mode "Apps" list, sends that app's **TCP** flows out the physical interface, past the VPN.
Why this first:
- The kernel engine cannot do it at all.
- It fails safe. If the extension is off, dead or unapproved, the app's traffic stays in the VPN. Nothing
  leaks. The spike confirmed it: after a `kill -9` the claimed app's next requests went into the VPN
  (Part B, B3).
- It writes no kernel routes, so it adds nothing to the route churn that has troubled GlobalProtect
  before (#65, #106).
- It needs no new DNS machinery. The cost of that: a bypassed app still resolves through the VPN's DNS
  (or through our forwarder for a wildcard), so the VPN's resolver sees the names it looks up, and a CDN
  may hand it an address for the VPN's region rather than the user's.
- Interface scoping is the egress the proxy listeners already use beside a VPN
  (`parameters.requiredInterface = interface`, `ProxyForwarder.swift:746`). The extension reaches it
  through the C Network API instead, because it must also carry the flow's metadata (3.5). The spike
  proved this egress leaves outside a connected full-tunnel VPN (Part B, B1).

**What stays on kernel routes:** everything that works today, in every mode. Domains, services, IPs,
CIDRs, wildcards, VPN Only and its blocks, multi-VPN, the helper, `/etc/hosts`, the forwarder. Three
reasons the kernel engine stays the default:
- Some Macs will never allow the extension (MDM sets `AllowUserOverrides=false`).
- Some users will never click the two approvals.
- Every byte the extension claims is copied through user space twice. Kernel routes cost nothing per byte.

**Later, in order:** proxy and Tailscale-peer routes for any app; UDP; hostname rules for connect-by-name
flows; per-app VPN-only last, because it fails open (if the extension dies, that app goes direct).

**Not planned:** a DNS proxy (GlobalProtect declares one, the forwarder already covers wildcards), a
content filter, a packet tunnel, TLS interception.

### 2.1 What the spike proved, and what it left open

The spike (`spikes/ne-proxy`, extension 0.1.4) ran on 2026-10-30 on the Mac mini (macOS 26.6.1, SIP
off, Tailscale connected) and on the owner's MacBook (macOS 27, a corporate full-tunnel VPN on
GlobalProtect connected). Everything below is from its two results files.

| Finding | Evidence | What it means for v1 |
|---|---|---|
| A claimed flow leaves on the physical interface while the VPN is connected; unclaimed flows stay in the tunnel | B1: claimed requests saw the home IP, unclaimed ones the VPN's; `tcpdump` showed the claimed download on the physical interface | The core idea works. 3.5 is the design the spike used |
| Matching by signing id works | A1, B1: `claimed.app` for the test client | Per-app matching (3.4 step 4) is proven for one CLI client. Browsers and other apps are L4 |
| Starting and stopping the proxy did not close flows it did not claim, under include-all-TCP too | A2 on the mini: an `ssh` session, two downloads and Tailscale's three sockets survived every start and stop, against a control period. B4 on the MacBook: the VPN client's connections were unchanged after the start and two minutes of traffic | R1 shrinks: a start or stop costs only the flows the engine itself carries. The configuration may stay enabled across reboots, unless L11 shows a boot-time start does harm (3.7) |
| macOS does **not** restart the extension after a crash | A3 and B3: after `kill -9` the session went to `disconnected` ("Plugin failed"), the configuration stayed enabled, no new process came back in 3 minutes | The old "the OS restarts it" assumption was wrong. The app's watchdog must notice and decide (3.7) |
| For about 5 s after a crash, every new flow the include rule covers waits | A3: new flows hung 4.6 to 5.0 s until "Extension exit timer expired", then went out as if no proxy were there. Under include-all-TCP that is every new TCP connection on the Mac, the VPN client's new ones included | R8 is real and measured: one 5 s stall per crash. Nothing in our code can shorten it; the watchdog limits how often it happens (3.7) |
| Claimed flows die at the 5 s mark; unclaimed open flows survive a crash | A3: claimed downloads ended with -1005; `ssh`, the unclaimed download and Tailscale's sockets survived | Only the listed apps lose connections when the extension dies |
| macOS fills in `remoteHostname` even for clients that resolve the name themselves | A1, B1: plain `curl` and `nc` to a listed name were claimed by host name, even with an IP literal | Good news for the later hostname stage, and a risk: a flow to an IP that a listed name shares may be claimed as that name. v1 matches no host names, so v1 is not affected |
| An NSURLSession HTTPS flow arrived already bound to an interface and was declined as `bound` | B4: `nscurl https://…` declined `bound` while `curl https://…` to the same host was claimed | Open, and it touches v1: an app whose flows arrive bound is never served, whatever its rule. Which interface they were bound to was not recorded. L4 measures it per app (3.4 step 3) |
| No app group and no `NEMachServiceName` are needed | the spike activated and ran on macOS 26.6.1 and 27 with only `NEProviderClasses` in the extension's `Info.plist` | Settled; 3.1 drops the fallback |
| A copy with the restricted entitlements and no embedded profile is killed at launch | L0 on the MacBook (SIP and AMFI on): exit 137 without the profile, the signed copy ran | R5 is real; the release gate in 6.3 must catch it |
| The status reply sometimes never arrived | A3: 3 of the status calls printed "no reply from the extension" while the session was connected; the next call answered | The heartbeat must retry before it calls the extension silent (3.7) |
| The approval alert and System Settings showed a blank icon | spike 0.1.4 had no icon in the extension bundle; 0.1.5 added `AppIcon.icns` to both bundles | The fix is in 6.1, but nobody has seen the 0.1.5 alert live. L0 checks it |

Not run, so still open:
- **B2**, 10 minutes of normal use with the policy pushed and the VPN connected. The owner's test runs it
  (section 10).
- **B3.2**, lease expiry: quit the app and see claimed apps go back into the VPN within 2 minutes. The
  lease logic is unit-tested in the spike, never seen live. The mini runs it in step 5.
- **`kill -9` under include-all-TCP beside GlobalProtect.** It ran under `all` on the mini only. The
  stall above says what to expect.
- **L9** (extension replaced by an update, `brew upgrade` and `brew uninstall`) and **L11** (consent and
  start at reboot or login) were never run.
- The exact System Settings path and prompt wording of the two approvals were not written down.

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
    Contents/Resources/AppIcon.icns     the app's icon (shown in the approval alert)
    Contents/embedded.provisionprofile
  embedded.provisionprofile             the app's profile
```

- Extension id: `com.geiserx.vpn-bypass.proxy`.
- Extension `Info.plist`: `NSSystemExtensionUsageDescription`, `LSMinimumSystemVersion` 15.0,
  `CFBundleIconFile` `AppIcon`, and
  `NetworkExtension = { NEProviderClasses = { com.apple.networkextension.app-proxy = FlowProxy } }`.
  The class is declared `@objc(FlowProxy)`, so the plist value is that bare name. CI checks that the
  value names a class in the built binary, because a mismatch shows only at activation. The spike's
  `scripts/build.sh` already does this check.
- No app group and no `NEMachServiceName` (settled by the spike, 2.1).
- The extension's `main.swift` is `autoreleasepool { NEProvider.startSystemExtensionMode() }; dispatchMain()`.

**macOS floor.** The app stays at macOS 13 (`Package.swift:8`, `Info.plist` `LSMinimumSystemVersion`). The
engine needs macOS 15: that is where the `nw_endpoint_t` flow APIs replaced the deprecated
`NWHostEndpoint` ones. SwiftPM sets one platform for the whole package, so the extension and the
app-side NE code carry `@available(macOS 15, *)`. On 13 and 14 the engine reports `unavailable` and never
files an activation request.

### 3.2 Entitlements, per binary

| Binary | Entitlements | Profile |
|---|---|---|
| `VPNBypass` (app) | what it has today (`VPNBypass.entitlements`: `app-sandbox` false, `network.client`, `automation.apple-events` for the front-tab read) plus `com.apple.application-identifier` `624WUVM8B4.com.geiserx.vpn-bypass`, `com.apple.developer.team-identifier` `624WUVM8B4`, `com.apple.developer.system-extension.install`, `com.apple.developer.networking.networkextension = [app-proxy-provider-systemextension]` | `MAC_APP_DIRECT` for `com.geiserx.vpn-bypass` |
| Extension | `com.apple.application-identifier` `624WUVM8B4.com.geiserx.vpn-bypass.proxy`, `com.apple.developer.team-identifier`, `com.apple.developer.networking.networkextension = [app-proxy-provider-systemextension]` | `MAC_APP_DIRECT` for `com.geiserx.vpn-bypass.proxy` |
| `vpnb`, helper | none (as today) | none |

The spike's `entitlements/app.entitlements` and `proxy.entitlements` are the working templates; they ran
under AMFI on the MacBook.

Rules learned from earlier AMFI incidents and the spike:
- On macOS 26 and later, AMFI SIGKILLs a binary that carries these restricted entitlements without an
  embedded matching profile, even when it is notarized (L0 on the MacBook, 2.1). The profile file must be
  named `embedded.provisionprofile`.
- The certificate inside each profile must be the signing certificate: `LTV59DZ9B4`, Developer ID
  Application G2, SHA-1 `0709E698...`, expires 2031-09-17.
- Never combine the NE entitlements with `cs.disable-library-validation` or
  `cs.allow-unsigned-executable-memory` on one binary. The app has no runtime relaxations today, and
  `automation.apple-events` is not one.
- The helper authorizes the app by identifier and team (`scripts/sign-and-notarize.sh:49`,
  `HelperAuthPolicy.callerRequirement`). Entitlements and a profile do not change that requirement.

**The one real packaging risk.** With the entitlements on the main app, a bad or missing profile kills the
whole app at launch, including the kernel engine everyone relies on. We accept that because one app is
simpler than a separate activator app plus IPC between them, but only behind a release gate that is proven
to go red (6.3). If no runner can make that gate fail, the fallback is a nested activator app (PIA's
layout: a sub-app inside the bundle that owns the extension and the entitlements), so the main binary
never carries them.

### 3.3 Config delivery

- **Never use `providerConfiguration`.** `/Library/Preferences/com.apple.networkextension.plist` is
  world-readable and holds other vendors' provider settings in clear text (`VPNKillSwitch.swift` reads it
  for that reason). Anything we put there is readable by every local user.
- **Use `sendProviderMessage`** on the manager's session, handled by `handleAppMessage` in the extension
  (the spike's way). The message is a versioned `FlowPolicy` blob:
  - generation number;
  - ordered matchers: for v1 only process matchers (bundle id or executable name) and the rule id;
  - per-rule egress: `direct(interface)`, later `vpn(utun)` and `proxy(port)`;
  - the physical interface name from `RouteManager.detectPhysicalInterface()` (`RouteManager.swift:6359`),
    the same one the proxy listeners bind to (`RouteManager.swift:6283`). The test Mac is dual-homed, so
    no interface name is ever hard-coded. When the policy names none, the extension picks the most
    preferred Wi-Fi or Ethernet interface itself (the spike's `Egress.pick`);
  - extra team ids to decline: the team of the process that owns each live tunnel
    (`TunnelOwnership`, read through the helper, `RouteManager.tunnelOwnersByInterface`), on top of the
    fixed list in `FlowDecider`;
  - a lease length.
- **Lease.** Same idea as the helper's wildcard lease (`HelperProtocol.swift:123-125`). Without a fresh
  policy within the lease (2 minutes), the extension declines every flow. That is today's
  behaviour, so a quit or crashed app can never leave stale per-app routing behind. A menu bar app that
  sits idle can have its timers delayed by App Nap and timer coalescing, so `FlowEngineManager` holds a
  `ProcessInfo` activity while the engine is on, the heartbeat runs every 30 s, and the extension counts
  lease expiries so a lapse is visible.
- **Unknown policy version.** An extension that receives a policy version it does not know (a new app
  talking to an old extension whose replacement is still pending, 6.4) declines every flow and reports the
  mismatch in the heartbeat reply.
- **When the app pushes:** on every rule or mode change (`commitAppliedRoutes`, `RouteManager.swift:3568`),
  on a network or VPN change (where the listeners re-bind, `reconcileProxyListeners`,
  `RouteManager.swift:6276`), on Pause and Resume (3.7), when the session turns `connected`, and on the
  heartbeat. A push needs no DNS, so it is not held up by the lookups that connect-from-cache works around.
- **Include rules never change at runtime.** They are set once in `startProxy` and cover all outbound TCP
  minus fixed exclusions (3.4). Every decision lives in the policy message, so a rule change never needs
  `setTunnelNetworkSettings`, a re-save of the manager, or a restart.
- The manager is saved only when its static fields changed. PIA saw consent lost on re-save
  (pia-foss/desktop#94).

### 3.4 Flow matching

`NENetworkRule` can match only remote address, port, protocol and direction, never the app. So per-app
routing must include broadly and decide per flow.

`includedNetworkRules`: one rule, `remoteNetwork nil`, protocol TCP, outbound. (`nil` matches every remote
except loopback, `NENetworkRule.h:116-122`.) The spike ran this as scope `all`.

`excludedNetworkRules` (fixed): 10/8, 172.16/12, 192.168/16, 169.254/16, 224/4, 100.64/10 (Tailscale, the
same range as `ProtectedDestinations`, `HelperProtocol.swift:512`), fc00::/7, fe80::/10, ff00::/8,
fd7a:115c:a1e0::/48. Apple says exclusions win, but FB14453214 reports them ignored, so `handleNewFlow`
repeats the checks. An exclusion on `0.0.0.0/8` with port 0 makes `setTunnelNetworkSettings` fail ("Either
a non-wildcard port or a non-wildcard address must be specified", spike 0.1.1), so that range is checked
in code only.

`handleNewFlow` is synchronous and must never block: no DNS, no I/O, no XPC. It reads one in-memory
table, in this order (the spike's `FlowDecider.decide`):
1. No live policy (none yet, unknown version, or lease expired): return `false`.
2. Flow from our own app, `vpnb`, helper or extension, or from `mDNSResponder`, captive-portal, push or
   NE daemons: return `false`. The helper's wildcard forwarder is ours, so its upstream lookups are never
   claimed.
3. `flow.isBound` is true (the app bound its socket to an interface): return `false`. The spike saw
   NSURLSession HTTPS flows arrive bound (2.1). v1 keeps declining them. The decider still compares the
   signing id with the matchers (an in-memory string compare) so the count lands on the rule
   (`declined.bound` per rule), and the group can say "this app picks its own network interface; per-app routing
   cannot serve it" instead of staying silent. Step 5 also records which interface they were bound to
   (physical, tunnel, other); claiming a flow bound to the physical interface is a later change, made
   only on that data.
4. Destination: IPv6 returns `false` (the app routes IPv4 only, `RouteKernel.swift`, and the forwarder
   answers AAAA empty); an excluded range returns `false`.
5. Match `metaData.sourceAppSigningIdentifier` against process matchers:
   - a bundle id matches exactly or on a dot boundary (`com.google.Chrome` covers
     `com.google.Chrome.helper`, but not `com.google.ChromeX`), unlike PIA's bare prefix;
   - a matcher without a dot is an executable basename, compared with the path from
     `sourceAppAuditToken` (pid, then `proc_pidpath`), cached per audit token.
   No match, or the matched rule's route is not Direct in v1: return `false`.
6. VPN and security clients: return `false`. They are recognised by **team identifier**, not signing id:
   GlobalProtect's daemon is signed `Identifier=PanGPS`, `TeamIdentifier=PXPZ95SK77`. `NEFlowMetaData`
   carries no team id, so the extension reads it from `sourceAppAuditToken`
   (`SecCodeCopyGuestWithAttributes`, then `SecCodeCopySigningInformation`), cached per audit token. It
   runs last, only for a flow that would otherwise be claimed, because it reads a code signature. The
   fixed list (Palo Alto `PXPZ95SK77`, Tailscale `W5364U7YZB` and the other VPN vendors the app detects)
   lives in the pure `FlowDecider`; the policy adds the live tunnel owners' teams (3.3). `ruleAdd` and
   the app chooser refuse a process rule that names a declined team's app.
7. Otherwise claim it (return `true`) and re-emit (3.5).

**Process rules and Custom's first match.** A process rule decides by app, the others by destination, so
for a listed app's TCP flow the process rule wins over any destination rule, wherever it sits in the
list. The Rules page and `vpnb` say so for process rules. A listed app's DNS lookups are not flows of that
app (they come from `mDNSResponder`), so its names still resolve as the destination rules say.

`remoteHostname` is not used for matching in v1. The spike showed macOS fills it in more often than
expected (2.1); hostname rules come later, each after its own live data.

### 3.5 Re-emit path

For a claimed flow, in this order (the order matters). The spike's `Egress.swift` and `TCPRelay.swift`
do this and are the starting point.
1. Build an `nw_parameters_t` from an empty stack: `nw_parameters_create`, the default protocol stack,
   a TCP transport with no-delay on and a 5 s connect timeout, IPv4 only, then
   `nw_parameters_require_interface` with the `nw_interface_t` of the policy's physical interface. Do not
   use `nw_parameters_create_secure_tcp` with the "disable TLS" sentinel from Swift: Swift hands it over
   as a new block, Network does not recognise it, and every claimed flow ran a TLS handshake against the
   server and failed (spike, `Egress.swift`). Do not copy PIA's source-IP bind: it moves zero bytes behind
   a VPN's `0/1` routes on macOS 26.3 (pia-foss/desktop#93).
2. Call `flow.setMetadata(params)`. Only a connection created from those parameters afterwards carries
   the original app's metadata, so a later transparent proxy sees that app, not our extension
   (`NEAppProxyFlow.h`, `setMetadata:`).
3. `nw_connection_create(endpoint, params)`. The Swift `NWConnection` API cannot carry the metadata.
4. The endpoint is the flow's `remoteFlowEndpoint`. For a connect-by-name flow that is host:port: dial
   the name with the same scoped parameters, so it resolves on the physical interface. The name is held
   in memory for that connection only, never logged or stored (3.8).
5. When the connection is ready, `flow.open`, then copy both ways with a bounded buffer per direction
   (Apple warns that unbounded buffering gets the provider jetsam-killed).
6. If the connect fails, close the flow with an error. A claimed flow cannot be handed back.
7. No read timeouts on idle claimed flows (Proton tears idle flows down after 3 s, which breaks
   long-lived connections).

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

The VPN client's own flows are never claimed: they are declined by team id (3.4 step 6), and no process
rule can name them. A start or stop of the proxy did not close flows it did not claim, the VPN client's
included (2.1). So the harm the engine can do is limited to the listed apps' connections and to the 5 s
stall after a crash.

- **Starts and stops the app makes.** Turning the engine on or off, saving the manager, filing an
  activation or replacement request, and the watchdog's actions below. Rules:
  - a turn-on or turn-off says once that the listed apps' open connections will be reset; there is no
    VPN warning any more, because the spike showed the VPN's connections survive;
  - rule changes never restart it (3.3);
  - the configuration may stay enabled across quit and reboot. If L11 shows a boot-time start does harm
    to the VPN, the fallback is the per-session engine: the app sets `isEnabled = false` when it quits and
    at logout, and the user turns it on again each session.
- **Starts the OS makes on its own.** Once the configuration is enabled, `nesessionmanager` may start the
  provider at boot or login (often while the VPN auto-connects) and after sleep and wake, and `sysextd`
  replaces or removes it on an update (6.4). After a crash it does **not** start it (2.1). L9 and L11
  cover the rest, first on the mini.
- **Crash.** Flows the extension was copying die; those are only the listed apps' flows. Every new TCP
  connection on the Mac waits about 5 s, then the session goes `disconnected` with the configuration
  still enabled, and new flows go out as if no proxy were there. The listed apps go back into the VPN,
  which is safe. The app's watchdog:
  - sees the session `disconnected` with the configuration enabled and a last disconnect error, and shows
    `failed` with "per-app routing stopped; your listed apps use the VPN";
  - starts the session again once, by itself (a start costs nothing the user has open, 2.1) and re-pushes
    the policy;
  - a second crash within 10 minutes: leaves it stopped, sets `isEnabled = false`, and says so. A Mac
    that stalls 5 s per crash must not do it in a loop. The user turns it on again by hand.
- **Silent extension.** The heartbeat reply can go missing once with the session healthy (2.1), so the
  heartbeat retries twice before it calls the extension silent. A silent extension with the session
  `connected` is treated like a crash.
- **App quits or crashes.** The lease runs out and the extension declines everything. The listed apps go
  into the VPN, which is safe.
- **A VPN with `includeAllNetworks` or `enforceRoutes`.** Interface scoping cannot escape it (Apple:
  `enforceRoutes` "supersedes the system routing table and scoping operations by apps"). 6.0 already
  detects it for the kernel engine (`VPNKillSwitch.swift`, `RouteManager.vpnKillSwitch`). The engine uses
  the same detection: while it is set, the app pushes a policy with no matchers and the card says why.
- **Pause.** The app's Pause (`RouteManager.pause`, `:3097`) pauses per-app routing too: it pushes an
  empty policy and Resume (`:3143`) pushes the real one. Pause is not an off switch: the include rule
  stays installed, so every new TCP connection still goes through a call into the extension, and a hang
  would still stall it (R8). The UI copy says so. Only Turn off (`isEnabled = false`) removes that call.

### 3.8 Logging and privacy

The extension sees app identities, destination IPs and sometimes hostnames. It must never log or persist
any of them, not even as `%{private}`.
- The extension logs through one function that takes a fixed `enum Event` and integers only (the
  spike's `SpikeLog`). A string cannot be passed, so a hostname cannot reach the log by accident.
- Counters only: flows claimed, declined by reason, failed, per rule id. They travel back in the
  heartbeat reply.
- Nothing is written to disk by the extension.
- `remoteHostname` is read nowhere in v1.
- The app's existing rule stands: Lookups is opt-in and no hostname is logged.

## 4. Integration with the existing code

New code shape:
- `Sources/VPNBypassPolicy/` (new target, pure, no resources): `FlowPolicy` (Codable),
  `FlowPolicyCompiler` (app side: config to policy) and `FlowDecider` (extension side: flow facts to
  verdict). Ported from the spike's `SpikePolicy`, minus host-name matching. Unit-tested like
  `RuleResolver` and `RouteCompiler`.
- `Sources/VPNBypassProxy/` (new executable target): the provider. It links `VPNBypassPolicy` and
  NetworkExtension only. It must not link `VPNBypassCore`: that target has resources, and its
  `Bundle.module` accessor would trap inside the extension.
- `Sources/VPNBypassCore/FlowEngineManager.swift` (new, `@MainActor`): activation request, manager save,
  policy push, heartbeat, watchdog, state machine.

The helper does not change. The extension never writes routes, and none of the new files is in the
Makefile's `build-helper` list, so the helper stays at 2.8.0 and `scripts/check-helper-version.py` has
nothing to say.

Touch points, by file:
- `RouteModel.swift:43`: keep `case process`; replace the "P3, NE-only" comment with a real definition of
  the pattern (bundle id or executable basename).
- `CommandRouter.swift:409` `ruleAdd`: validate a process pattern (bundle-id shape or a bare basename,
  no path, no wildcard, not a declined team's app).
- `RuleResolver.swift:29,45`, `RuleDestinationBuilder.swift:18,73,99`, `WildcardRoutes.swift:92`: no
  change. Process rules stay invisible to the kernel engine; the extension serves them.
- `ConfigModel.swift:265` `derive`: the Bypass-mode "Apps" list derives to process rules with the Direct
  route, the same way the domain list derives to domain rules. Add `bypassApps: [String]` and
  `flowEngine: { enabled: Bool }` with `decodeIfPresent` (as `ConfigModel.swift:159-163` does); old builds
  ignore both, no `schemaVersion` bump.
- `RouteManager.swift:3568` `commitAppliedRoutes`, `:6276` `reconcileProxyListeners`, `:3097` `pause` and
  `:3143` `resume`: call `FlowEngineManager.pushPolicy()`.
- `RouteManager.swift:2448` `refuseVPNOnlyUnderGlobalProtect`: unchanged. VPN Only stays kernel-only.
- `ControlSurface.swift:89` and `CommandRouter.swift:109` `RuntimeStatus`: add `flowEngine` with the
  state, policy generation and per-rule counters. No names, no IPs.
- `CommandRouter.swift:260` `isMutating`: add `engine.on` and `engine.off`; new read verb
  `engine.status`. `engine.on` can only file the activation request; the reply says approval is waiting
  in System Settings. All additive, so the envelope `v` is not bumped.
- `CommandRouter.swift:189` `SanitizedRule` gains `servedBy: kernel | flow | inactive`.
- `RulesTab.swift:954` (the Match picker, today Domain, Service, IP, CIDR): add App, with an app chooser
  (bundle ids from /Applications) plus free text. `RulesTab.swift:768` already has the row glyph.
- `GeneralPage.swift`: the "Per-app routing" group (5).
- vpn-bypass-mcp (separate repo, after 6.1.0): pass the new status fields through; add `engine_status`
  (read) and `engine_on`/`engine_off` (destructive).

How the engine sits beside what 6.0 added:

| 6.0 feature | Effect on the engine |
|---|---|
| Wildcard forwarder and `/etc/resolver` files (helper) | None. The forwarder is ours, so its lookups are declined (3.4 step 2). A listed app's names still resolve through it |
| Delegated resolvers (Tailscale, a VPN's split DNS) | None: DNS is not proxied, and 100.64/10 and private ranges are excluded |
| VPN Only and its blocks while the VPN is down | The engine does not run in VPN Only (no matchers pushed) |
| Tunnel attribution (`TunnelOwnership`) | Feeds the extra declined teams in the policy (3.3) |
| Helper self-update (2.8.0) | None: the helper does not change. The extension has its own update path (6.4) |
| Kill-switch detection (`VPNKillSwitch`) | The engine stands down on the same signal (3.7) |
| Pause | Pauses the engine too (3.7) |
| Connect-from-cache | None: a policy push needs no DNS |
| Custom rule model (routes, first match, `VPNSelector`) | Process rules with the Direct route only in v1; any other route shows "inactive: not in this version". Process rules win for their app's flows (3.4) |

Modes:
- **Bypass:** the new "Apps" list. Listed apps go direct.
- **Custom:** process rules with the Direct route in v1; VPN-pinned and proxy routes in later stages.
- **VPN Only:** no per-app in any planned stage.

## 5. Opt-in UX and fallbacks

**Settings > General, "Per-app routing" group**, off by default. Before any system prompt it says:
- what it does: only apps you list skip the VPN;
- macOS will ask twice: first allow the extension in System Settings, then allow VPN Bypass to add a
  proxy configuration (the exact path and wording come from L0);
- if you say no, nothing else changes.

Every control has a VoiceOver name, and every string is in English, Spanish and French
(`scripts/check-localizations.py`).

**States** shown in the group, the menu and `vpnb status`:

| State | Meaning | Process rules show |
|---|---|---|
| `unavailable` | macOS below 15, or a build without the entitlements (dev and CI) | "needs macOS 15" or "not in this build" |
| `off` | the user has not turned it on | "inactive: per-app routing is off" |
| `awaitingExtensionApproval` | request filed, user has not allowed it | "waiting for approval" plus the System Settings path |
| `awaitingConfigApproval` | extension allowed, proxy configuration prompt pending | same |
| `blocked` | MDM forbids it, or the app is not in /Applications | the reason; stop asking |
| `starting` | | |
| `active` | | "served by per-app routing" |
| `paused` | the app's Pause, or a VPN kill switch | "paused" and why |
| `failed` | a crash, a silent extension, or two crashes in 10 minutes | the reason, and that the listed apps use the VPN |

In every state except `active`, the kernel engine runs as today. No process rule is ever a silent
no-op again: from step 2 on, a process rule says it is inactive and why.

**Remove.** An in-app "Remove per-app routing" does `removeFromPreferences`, then a deactivation request.
Homebrew cannot do it: a cask cannot launch the app. We expect `brew uninstall` to leave the extension
active until reboot, but nobody has tested it; L9 checks it. The troubleshooting doc gets a "remove the
extension" entry with the System Settings switches and `systemextensionsctl` steps (the spike README's
"If it misbehaves" list is the draft).

## 6. Packaging, CI and the cask

### 6.1 Build (no Xcode project)

- `Package.swift`: targets `VPNBypassPolicy` and `VPNBypassProxy` (product `com.geiserx.vpn-bypass.proxy`).
  The universal `swift build --arch arm64 --arch x86_64` already builds every product (`Makefile:16`).
- `Makefile` `bundle` (`:58`): copy the binary, `Proxy/Info.plist` and `assets/AppIcon.icns` into
  `Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension/`. Stamp
  `CFBundleShortVersionString` and `CFBundleVersion` like the app's. macOS replaces the extension only
  when its version changes.
- `make run` opens the app from the repo, where activation fails ("must be in /Applications"). Only
  installed builds can activate. Dev builds are unsigned and report `unavailable`.

### 6.2 Signing (`scripts/sign-and-notarize.sh`, mode `app`, `:65-90`)

The script already signs inside out and checks that the app's signed entitlements equal the file passed
with `--entitlements`. Added:
1. helper and `vpnb` as today;
2. copy the extension profile to `<ext>/Contents/embedded.provisionprofile`, sign the extension with
   `entitlements/proxy.entitlements`;
3. copy the app profile to `Contents/embedded.provisionprofile`, sign the app with
   `entitlements/app.entitlements` (today's `VPNBypass.entitlements` plus the NE keys, 3.2);
4. verify: `--verify --deep --strict`, the helper requirement, the signed entitlements of both against
   their files, and `security cms -D` on both profiles: certificate SHA-1 equals the signing identity's,
   `application-identifier` is `624WUVM8B4.<id>`, profile entitlements are a superset of the signed ones,
   not expired (the spike's `scripts/sign.sh` does these checks);
5. notarize and staple as today. The nested extension is covered by the app's ticket.

`VPNBypass.entitlements` moves into `entitlements/app.entitlements`; `Makefile:140` and the auto-tag path
filter follow it.

Local signing for tests happens only on the Mac mini, inside a temporary keychain that is deleted
afterwards. Profiles live outside the repo.

### 6.3 CI and release

- `release.yml`: two secrets, `PROVISIONING_PROFILE_APP_BASE64` and `PROVISIONING_PROFILE_PROXY_BASE64`,
  decoded into `$RUNNER_TEMP`. A missing secret fails the release, as the other signing secrets do today
  (step "Import signing certificate").
- **Launch gate.** `ci.yml` already launches the unsigned bundle (`scripts/smoke-launch.sh`, job "build
  and launch app"), and `release.yml` waits for that job. Nothing launches the **signed** app. Add a step
  after `make release` that runs `scripts/smoke-launch.sh` on the stapled app and fails if it dies in the
  first seconds. Prove the gate can go red once with a deliberately wrong profile. If the runner does not
  enforce AMFI, the gate is worthless and 3.2's fallback (nested activator) applies.
- `ci.yml`: add the extension binary to the universal-architecture loop (`:117-126`); assert its
  `Info.plist` has `SYSX` and `NetworkExtension`, and that its `NEProviderClasses` value is an ObjC class
  in the built binary. CI bundles stay unsigned and entitlement-free.
- `auto-tag.yml:23-31`: replace `VPNBypass.entitlements` with `entitlements/**`. On `release/6.1` this has
  no effect; it matters when the branch merges into `main`.
- `.gitignore`: add `*.provisionprofile`. Profiles and keys never enter git.

### 6.4 Cask

No change to the stanzas. `app` installs to /Applications. A user with `--appdir=~/Applications` gets
`unsupportedParentBundleLocation`; the engine shows `blocked` with that reason and the kernel engine
keeps working. No preflight or postflight (`release.yml:224-233` already fails on one). The app relaunches
itself after an update (`AppUpdateRelauncher.swift`) and files the activation request again; the delegate
answers `.replace` when the version differs. On the mini, a higher version replaced the spike's extension
with no new approval and ended its session (spike README, "Rebuilding"), so after a replacement the app
starts the session again and re-pushes.

Part of the update is not ours to control. Homebrew removes the old bundle and then moves the new one in
(`AppUpdateRelauncher.swift` names the `missing` state in between). `sysextd` may treat the containing app
as removed and stop or uninstall the running extension before our app runs again. Given 2.1 that costs
the listed apps' connections, not the VPN's, but L9 must still say what happens, with a real
`brew upgrade` and an in-place bundle swap.

When the extension replacement waits (the user has not approved it yet), a new app talks to an old
extension: the policy carries a version, and an extension that does not know it declines every flow
(3.3), so per-app routing stops and the group says an update of the extension is waiting.

## 7. App Store Connect

**State on 2026-11-04** (read-only API calls with the team's App Manager key, team 624WUVM8B4):

| Bundle id | ASC id | Platform | Capabilities | Profile |
|---|---|---|---|---|
| `com.geiserx.vpn-bypass.spike` | `KLY8U6HHCZ` | `UNIVERSAL` | `SYSTEM_EXTENSION_INSTALL`, `NETWORK_EXTENSIONS`, `IN_APP_PURCHASE` | "VPN Bypass NE spike app DevID", `MAC_APP_DIRECT`, `ACTIVE`, expires 2031-09-17 |
| `com.geiserx.vpn-bypass.spike.proxy` | `5BJDJSV4HL` | `UNIVERSAL` | `NETWORK_EXTENSIONS`, `IN_APP_PURCHASE` | "VPN Bypass NE spike proxy DevID", `MAC_APP_DIRECT`, `ACTIVE`, expires 2031-09-17 |
| `com.geiserx.vpn-bypass` | none | | | none |
| `com.geiserx.vpn-bypass.proxy` | none | | | none |

What the spike taught about the API:
- The spike's `scripts/asc-profiles.py` created both ids, their capabilities and both profiles through
  the API, so the App Manager role is enough; nobody has to use the portal.
- It posted `platform MAC_OS`; the ids came back as `UNIVERSAL`. That is fine for Developer ID profiles.
- Apple added `IN_APP_PURCHASE` by itself. It is harmless; leave it.
- The profile allows more NE values than we sign with (`packet-tunnel`, `app-proxy` and
  `content-filter`, each with `-systemextension`). The signed entitlements must be a subset, and they are.

**Remaining steps** (step 4 of section 10). They run once, are idempotent, and use the same key:
1. Move `spikes/ne-proxy/scripts/asc-profiles.py` to `scripts/asc-profiles.py`, with the two real ids in
   its table: `com.geiserx.vpn-bypass` (capabilities `SYSTEM_EXTENSION_INSTALL`, `NETWORK_EXTENSIONS`)
   and `com.geiserx.vpn-bypass.proxy` (`NETWORK_EXTENSIONS`). Profile names "VPN Bypass app DevID" and
   "VPN Bypass proxy DevID". It keeps its `--dry-run`, and it reads capabilities before posting any,
   because re-posting an enabled capability turns existing profiles INVALID.
2. Run it with `--dry-run`, read the plan, then run it for real.
3. Check both profiles: `profileState ACTIVE`, the certificate is `LTV59DZ9B4` (SHA-1 `0709E698...`),
   `application-identifier` is `624WUVM8B4.<id>`, and the NE values carry the `-systemextension` suffix.
4. Store both as the GitHub secrets `PROVISIONING_PROFILE_APP_BASE64` and
   `PROVISIONING_PROFILE_PROXY_BASE64`, and keep a copy in the private profiles folder outside the repo
   that the mini's signing reads.
5. Leave the spike's ids and profiles alone until 6.1.0 has shipped; deleting them is optional cleanup.

Registering `com.geiserx.vpn-bypass` changes nothing for today's releases: they sign without a profile,
and the helper's requirement checks identifier and team only.

## 8. Test plan

### 8.1 Unit (Mac mini, `swift test`)

- `FlowDecider`: no policy declines; expired lease declines; unknown policy version declines; self,
  system daemons and VPN clients decline (VPN clients by team id, with a bare-identifier case such as
  `PanGPS` under team `PXPZ95SK77`, and a team added by the policy); `isBound` declines and counts;
  bundle-id dot-boundary match (positive `com.x.App.helper`, negative `com.x.AppX`); basename match; IPv6
  declines; excluded ranges decline; a non-Direct route declines; Direct claims; a host name alone never
  claims.
- `FlowPolicyCompiler`: Bypass "Apps" and Custom process rules compile to the same matchers; rule order
  kept; Pause, VPN Only and a VPN kill switch compile to no matchers; no hostname or credential ends up
  in the blob (assert on the encoded bytes).
- `ruleAdd` validation: accepts bundle ids and basenames, rejects paths, wildcards and declined-team apps.
- `FlowEngineManager` state machine with a fake manager: crash then one restart, second crash within
  10 minutes turns it off, heartbeat retries before "silent".
- Logging: a compile-time check that the extension's log function takes no `String`.
- Each new test is first run against a deliberately broken implementation and must fail.

### 8.2 The Mac mini: the first live tests

The mini runs macOS 26 with SIP off and system extension developer mode on, so it can install and
activate a signed build without the owner. It cannot test AMFI (L0): AMFI does not enforce signatures
there. It has no GlobalProtect; Tailscale's connections stand in for a VPN client's, as in the spike, and
a throwaway WireGuard tunnel can add a full-tunnel VPN. Everything installed for a test is removed
afterwards (deactivate, remove the app, launchd state).

### 8.3 Live tests

Hard rules for every step: never restart, reconnect or reconfigure GlobalProtect or any VPN; watch only.
Read GlobalProtect's logs for `Broken pipe` and reconnects before, during and after each step. If
GlobalProtect drops at any point, turn the engine off and write down the time.

**The owner's approval steps** (only the owner does these on his Mac; the agent never activates anything
there):
1. Install the signed `release/6.1` build to /Applications.
2. Settings > General > Per-app routing > Turn on. macOS says the system extension was blocked.
3. Allow it in System Settings and enter the admin password. Write down where the switch really was.
4. Back in the app, allow the proxy configuration prompt. Write down its wording.
5. Confirm with `systemextensionsctl list` (`activated enabled`) and the group showing `active`.

| # | Question | Where | State |
|---|---|---|---|
| L0 | Does AMFI accept the signed app and extension? Does the approval alert show the app's icon? | owner's Mac | spike: answered for AMFI (2.1); icon not seen |
| L1 | Does a start or stop close flows the engine does not claim? Plus a reboot or login with the configuration enabled while the VPN connects | mini, then owner's Mac | spike: answered for start and stop, on both Macs (2.1). The reboot part is L11 |
| L2 | Does a claimed flow leave on the physical interface? One rule, a test binary only | owner's Mac | spike: answered (B1) |
| L3 | Does GlobalProtect react (HIP report, enforcer, re-route) to scoped egress? | owner's Mac | spike: nothing seen in two minutes (B4); the soak answers it |
| L4 | Which signing id and `isBound` arrive for Safari, Chrome helpers, a URLSession app, curl, an unsigned Go binary; and for bound flows, which interface? Counters only | mini, then owner's Mac | open; bound HTTPS flows seen (2.1) |
| L5 | With another transparent proxy enabled too: who sees flows first, and does `setMetadata` keep attribution? | owner's Mac | open |
| L6 | Sleep and wake, Wi-Fi to Ethernet: new flows still claimed and leaving on the new interface | owner's Mac | open |
| L7 | UDP: does an include rule for UDP break Chrome QUIC for flows we decline? (gates the UDP stage) | later | open |
| L8 | `kill -9`: what happens to new and open flows, does the OS restart it, and does the watchdog do what 3.7 says? | mini | spike: answered for the OS side (2.1); the watchdog is new |
| L9 | Extension version bump by a real `brew upgrade` and by an in-place bundle swap, with the engine active: does `sysextd` stop or uninstall it, does the configuration stay enabled, is a new approval asked, are unclaimed flows untouched? `brew uninstall`: is it active until reboot? | mini | open |
| L10 | Throughput and CPU through the extension against direct; added latency of new connections | mini | open |
| L11 | Does the consent survive a reboot (PIA #94)? Does the OS start the provider at boot or login, and does that touch the VPN's or Tailscale's connections? | mini | open |
| L12 | Soak: 10 minutes of normal use (the spike's B2), then a working day with GlobalProtect connected; drops against a day with the engine off. GlobalProtect logs local time, ours UTC | owner's Mac | open |
| L13 | Lease expiry (the spike's B3.2): quit the app, listed apps go back into the VPN within 2 minutes | mini, then owner's Mac | open |

Before L4 is answered, every live step uses one narrow rule: a test binary, never a browser.

## 9. Risks

| # | Risk | Hard or impossible |
|---|---|---|
| R1 | Starting the proxy closes flows | **Hard, mostly answered.** The spike saw only claimed flows close, on both Macs, the VPN client's untouched (2.1). Left: the OS's own starts at boot and login (L11) and on an update (L9). Fallback if they do harm: the per-session engine (3.7) |
| R2 | Order between several transparent proxies is unspecified without MDM; another proxy running after ours may re-route our flows into the tunnel | **Impossible to control** from our side without MDM's `Order` (an OS rule). Mitigation: `setMetadata` so attribution survives; detect and report via L5 |
| R3 | A VPN with `includeAllNetworks` or `enforceRoutes` | **Impossible** to escape: Apple says it supersedes scoping by apps, and `NETransparentProxyManager` cannot opt out. We stand down and say so (3.7) |
| R4 | MDM sets `AllowUserOverrides=false` | **Impossible** on that Mac unless its admin allow-lists team 624WUVM8B4. Kernel engine stays |
| R5 | Bad profile kills the whole app at launch | **Hard.** Seen in the spike (2.1). Release launch gate proven red (6.3), or the nested activator |
| R6 | Chrome QUIC breaks on diverted UDP | **Hard**, an Apple bug (FB23636906). v1 is TCP-only; UDP waits on L7 |
| R7 | Apps whose flows arrive bound, or resolve-then-connect apps with no host name | **Hard.** Bound flows are declined and the group says so (3.4 step 3); L4 says how common they are. Name rules keep using kernel routes and the forwarder |
| R8 | A crash stalls every new TCP connection on the Mac for about 5 s, paused or not (the include rule stays installed) | **Hard, measured** (2.1). The OS sets the 5 s, not us. Never block `handleNewFlow`; at most one automatic restart, then off (3.7). Only Turn off removes the exposure |
| R9 | Throughput loss through user space | **Hard.** Claim only listed apps' flows; L10 measures |
| R10 | Known Apple bugs with any transparent proxy installed: FaceTime/AirDrop, captive portals, flows lost after sleep | **Hard**, outside our code. Decline Apple daemons, pause on captive networks, document; L6 |
| R11 | Homebrew cannot remove the extension | **Hard.** In-app remove plus a documented manual path |

## 10. The plan: one PR per step

Base branches. A merge into `main` that touches `Sources/**` (or the other paths in `auto-tag.yml`)
cuts a release by itself. So only steps 1 and 2 target `main`. Step 2 creates `release/6.1` from `main`
after it merges; steps 3 to 7 target `release/6.1`, never touch `main` and never release. `release/6.1`
merges `main` whenever `main` moves, so the final PR is small. Step 8 opens the `release/6.1` to `main`
PR and does not merge it: the owner merges it after his live test, and that merge cuts 6.1.0 (a `feat`,
so a minor).

1. **This doc** (`main`, docs only, no release).
2. **Stop the silent no-op** (`main`, ships as a 6.0.x patch). A process rule shows "inactive: per-app
   routing is not in this version" on the Rules page, in `vpnb rule.list` (`servedBy`) and in the MCP
   status; `vpnb rule.add match=process` validates the pattern. No NE code. Then create `release/6.1`.
3. **Pure policy** (`release/6.1`). `VPNBypassPolicy` with `FlowPolicy`, `FlowPolicyCompiler`,
   `FlowDecider`, ported from the spike's `SpikePolicy` without host-name matching, with the tests of
   8.1. No NE code.
4. **App Store Connect and signing** (`release/6.1`). The remaining steps of section 7; the
   `entitlements/` directory; the signing script for the extension and both profiles; `release.yml`
   secrets and the signed-app launch gate, proven red once; `ci.yml` checks; `.gitignore`. The bundle
   carries an extension that declines every flow, and the app does nothing with the entitlements yet.
   Signed and launched on the mini.
5. **The engine** (`release/6.1`). The extension with the TCP copier (from the spike's `Egress` and
   `TCPRelay`) and `FlowEngineManager`: activation, manager save, policy push, heartbeat with retry,
   lease, watchdog, kill-switch and Pause stand-down, `vpnb engine.*` and the status fields. Driven from
   `vpnb` only; no UI yet. On the mini, with a signed build: L1, L8, L9, L11, L13 and the bound-interface
   counters of L4.
6. **The UI** (`release/6.1`). The Per-app routing group and its states, the App match in Custom's rule
   sheet with the app chooser, the inactive and bound notes on process rules, en, es and fr strings,
   VoiceOver names, before and after screenshots.
7. **Bypass-mode "Apps" list, remove path, docs** (`release/6.1`). The "Apps" list and its `derive`, the
   in-app remove, the troubleshooting entry, the user docs.
8. **Open `release/6.1` into `main`** (not merged). Gate before opening it: L1, L8, L9 and L11 green on
   the mini with the build from the branch's head. The PR body lists the owner's test: the approval steps
   in 8.3, then L0 to L4, then the soak (L12: B2's 10 minutes, then a working day). He merges after it.

After 6.1.0: the MCP server's tools (its own repo), then proxy and Tailscale-peer routes for any app
(relay claimed flows to the route's loopback listener with `CONNECT` plus the local secret; it needs
`LoopbackPeerAuth.allows(peerUID:)`, `LoopbackPeerAuth.swift:15`, which today accepts only the app's own
uid, to accept the root extension by its code requirement), then UDP if L7 allows it, then VPN-pinned
process rules and hostname rules, each after its own live data.

## Sources

- Spike: `spikes/ne-proxy/README.md`, `RESULTS-PART-A.md`, `RESULTS-PART-B.md`
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
