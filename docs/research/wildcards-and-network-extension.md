# Wildcard domains and Network Extension: decision document

Research of October 2026. It describes what we decided to build and why; option B below is built (helper 2.5.0); Network Extension is not.

**Terms used below**
- **Host route:** a kernel routing-table entry for one IP address (`/32`).
- **Resolver file:** a file in `/etc/resolver/<suffix>`. macOS sends lookups for names under that suffix to the server named in the file (`man 5 resolver`).
- **Network Extension (NE):** Apple's framework for networking add-ons. Shipping one needs restricted entitlements, embedded provisioning profiles and user approval.
- **DoH / DoT:** DNS over HTTPS / DNS over TLS. These are encrypted lookups that an app sends itself, so the macOS resolver never sees them.
- **The race:** the app gets its DNS answer and connects before our route exists, so the first connection takes the wrong path.

---

## 1. Recommendation

Ship wildcards now through a **scoped local resolver inside the existing root helper**, with no Network Extension.

For each wildcard, the helper writes `/etc/resolver/<suffix>` pointing at its own forwarder on `127.0.0.1:53530`. The forwarder sends the query upstream to the right DNS server. For every IPv4 address in the answer it **adds the host route first and returns the answer second**. That removes the race for every app that uses the system resolver. Chrome is included: its built-in DNS client switches to the system resolver whenever more than one non-mDNS resolver exists (Chromium `net/dns/dns_config_watcher_mac.cc:95-108`).

This is always on while at least one wildcard exists. It does not depend on the Lookups switch. It works for the Bypass list, the VPN Only list and Custom-mode `suffix` rules routed Direct or through a VPN route pinned to one tunnel, at any depth. Proxy and Tailscale Peer routes get no wildcard forwarder: a kernel route cannot point at a listener.

On Network Extension: yes, it is worth thinking about, but not for wildcards.
- A DNS proxy (`NEDNSProxyProvider`) would do the same job the forwarder does. It costs entitlements, two provisioning profiles, hand signing and an approval prompt, and it still can't see DoH. It does **not** need MDM on macOS.
- The NE option that adds something new is a **transparent proxy (`NETransparentProxyProvider`)**. It gives per-app routing, routing proxy traffic by hostname, and blocking browser DoH. That makes it the right second engine for Custom mode later: opt-in, with the current engine as the fallback.
- Any NE work is still covered by the 2026-07-03 rule "no NE entitlements, ever" (`docs/MULTI-ROUTE-DESIGN.md:359`). That rule was reopened on 2026-10-05 but not lifted, so NE waits until the owner explicitly says go.

So the answer is: build the forwarder now, and treat NE as a separate per-app feature, not as the wildcard fix.

---

## 2. Options

### A. Continuous DNS capture (tcpdump in the helper, always on)

**How:** keep `DNSCapture` running whenever a wildcard exists. Read the responses (`udp src port 53`; today's filter is outbound queries only), match names against `*.suffix`, and add routes for the answer IPs.

**Pros**
- It mostly exists already: `Helper/DNSCapture.swift:21` runs root `tcpdump -i any -Q out -p -l ... "udp dst port 53"`.
- It sees plain DNS sent to any server, including hardcoded ones, because it captures on `-i any`.
- It needs no change to the DNS configuration.

**Cons**
- **It always races.** It sees the answer at the same moment the app does. Both paths take roughly 0.2–2 ms, so neither wins reliably (inferred). Today it is worse than that:
  - The output goes to a pipe, so tcpdump is not in immediate mode (`man tcpdump`: immediate mode is the default only when printing to a terminal). Packets wait in the capture buffer until libpcap's timeout, about 1 s by default (inferred). `-l` (`DNSCapture.swift:21`) only line-buffers stdout and does not fix this.
  - A learned route can wait behind a batch running on `routeQueue` (`HelperTool.swift:92`; batch handlers `:103-171`, `:376`).
- **What losing the race costs (inferred).** In Bypass mode the first connection was opened with the tunnel's source address. After our route appears it either stays in the tunnel or breaks. With HTTP/2 or keep-alive that can last hours. In VPN Only mode the first connection leaks outside the tunnel or fails.
- **Gaps:**
  - DNS over TCP (the filter is UDP only).
  - Encrypted system DNS (DDR or an MDM DNS profile), where there is no port-53 traffic at all.
  - DoH in browsers.
- The Lookups page is opt-in today (`DNSLookups.swift`; 60 s lease at `DNSCapture.swift:22,117-128`). An always-on capture changes that privacy promise.

**Verdict:** it works, but it is not "always working". Keep it only as a possible later supplement for apps that hardcode a plain-DNS server.

### B. Scoped local resolver in the helper (recommended)

**How:** see §1. Details:
- **Mapping.** `*.us5.datadoghq.com` becomes `/etc/resolver/us5.datadoghq.com`, and `*.datadoghq.com` becomes `/etc/resolver/datadoghq.com`. macOS "chooses the client with the maximum number of matching domain components", so every depth is covered (`man 5 resolver`).
  - The file also catches the apex (`datadoghq.com`). That matches `domainMatchesSuffix` (`RuleResolver.swift:69-71`).
- **Shadowing.** Our file overrides any less specific resolver for that suffix: Tailscale's split DNS, GP's corporate default, another tool's file. A more specific file (for example the existing `an existing `/etc/resolver/<corporate suffix>` file`) overrides ours.
  - On add, read `scutil --dns` and warn when a more specific resolver will hide part of the wildcard.
- **File contents:** `nameserver 127.0.0.1`, `port 53530`, `search_order 1`.
- **Upstream.** Send each query to the server that would have answered without our file, unless the route says otherwise.
  - Bypass mode and Direct routes: the non-VPN DNS server (`RouteManager.swift:5194-5251`). Bind the socket to the physical interface: `IP_BOUND_IF` on a BSD socket (new code), or `NWParameters.requiredInterface` as `ProxyForwarder.swift:746` does.
  - VPN Only mode and VPN routes pinned to a tunnel: the DNS servers of that tunnel's resolver, with the socket bound to its `utun`. This keeps internal names under a corporate suffix working.
  - Never `getaddrinfo`. It would send the query straight back to our forwarder.
- **Records we can't route.**
  - The app routes IPv4 only: `RouteKernel.ipv4ToUInt32` (`RouteKernel.swift:312`, used `:79-87`).
  - AAAA for a matched name therefore gets an empty NOERROR answer.
  - HTTPS/SVCB answers have their `ipv6hint` removed, and their `ipv4hint` addresses are routed or removed.
- **TTL.** Cap matched answers at about 300 s, so each re-query refreshes the "last seen" time.
- **Learned routes join the existing bookkeeping.**
  - They use the `RTF_PROTO1` tag (`RouteKernel.swift:69-90`) and the same pacer (`HelperTool.swift:212-218`, `RouteKernel.swift:538`).
  - The helper reports them to the app through a drain call, the same pattern as `drainDNSQueries` (`HelperProtocol.swift:94`).
  - The app records each one as an `ActiveRoute` with `source = "*.suffix"`.
  - The startup sweep (`RouteManager.swift:4974-4982`) and `reconcileMissingRoutes` (`:4913`) must include them.
  - A small on-disk ledger lets routes survive restarts.
  - A route expires after 24 h unseen with no open TCP connection to it.
- **Safety guard (new attack surface).** Whoever controls DNS for a wildcard zone now chooses which IPs get routes. The helper refuses to learn:
  - RFC1918, CGNAT, link-local, loopback and multicast addresses;
  - the VPN server's IP and the DNS servers in use;
  - any IP inside a VPN Only CIDR;
  - anything in `ProtectedDestinations` (`HelperProtocol.swift:283-330`). Today that list covers only Tailscale's range, MagicDNS, loopback, link-local and multicast; the rest is new code.

  It also caps learned IPs per wildcard and per minute.

**Pros**
- **No race** for anything that uses the system resolver, Chrome included. The added latency is one routing-socket write, tens of microseconds (inferred).
- It handles UDP and TCP DNS. With encrypted system DNS, mDNSResponder should still talk plain DNS to our file (inferred; spike check (g)).
- No entitlement and no approval prompt. It reuses the helper, the pacer and the route ownership that already exist.
- **Resolver files are proven beside GlobalProtect on the test Mac.**
  - With GP connected (default route on its utun), an existing corporate resolver file is live as `scutil --dns` resolver #10 (order 1).
  - It sits next to GP's default resolver (#2) and Tailscale's supplemental resolver (#1, utun10).
  - Not yet proven: a loopback server on a non-53 port. `man 5 resolver` documents the `port` keyword.
- **Same pattern as shipping tools.**
  - tailscaled-on-macOS (the open-source daemon, not the NE app installed here) writes `/etc/resolver/<suffix>`: https://github.com/tailscale/tailscale/blob/main/net/dns/manager_darwin.go (lines 33-41)
  - puma-dev uses a loopback port: https://github.com/puma/puma-dev
  - Cloudflare WARP documents "dynamically inserting the IP address of the domain immediately after it is resolved into the routing table", with the same shared-IP caveat: https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/configure-warp/route-traffic/split-tunnels/
- The model already has the pieces:
  - `MatchType.suffix` (`RouteModel.swift:39`) and `domainMatchesSuffix` (`RuleResolver.swift:69-71`). Today `RuleDestinationBuilder` emits nothing for them (`RuleDestinationBuilder.swift:18,73`).
  - `DomainEntry.isWildcard` (`ConfigModel.swift:526`).

**Cons**
- It adds code that must not break: a DNS listener with a minimal parser, a ledger, and an XPC protocol bump with a helper reinstall.
- **Unknowns that need a spike:**
  - GlobalProtect's system extension (6.2.8) declares `dns-proxy`, `app-proxy`, `filter-data` and `filter-packet` classes. No GP DNS proxy is enabled today. If an admin enables one, would it take over the forwarder's `en0`-bound port-53 upstream query? The mDNSResponder-to-`127.0.0.1:53530` hop is not a port-53 flow, so a DNS proxy should not see it (inferred from the `NEDNSProxyProvider` docs).
  - Does a steady trickle of single route writes stay clear of GlobalProtect's tunnel-teardown check?
- **Not covered:** custom routes to HTTP or SOCKS proxies. Kernel routes can't send traffic to an explicit proxy.

### C. Network Extension

Bound by `docs/MULTI-ROUTE-DESIGN.md:359` (no NE entitlements) until the owner lifts it.

| Provider | Wildcards | Per-app | Sees DoH | Fit |
|---|---|---|---|---|
| `NEDNSProxyProvider` | Strong. Can hold the answer until the route is in | Can likely identify the app from flow metadata (unverified), can't steer it | No | Same result as B, at NE cost. Developer ID system extension, **no MDM needed on macOS** (TN3134). Its one extra: it gets every socket "to UDP port 53 or TCP port 53", including hardcoded servers (https://developer.apple.com/documentation/networkextension/nednsproxyprovider) |
| `NETransparentProxyProvider` | Strong when the app connects by name. Resolve-then-connect apps (Chromium, curl, Go) arrive as IPs only and still need a name-to-IP map. The provider "ignores NEDNSSettings", and connect-by-name flows "don't bypass DNS resolution" (https://developer.apple.com/documentation/networkextension/netransparentproxyprovider). Quinn's "If a third-party app uses the resolve-then-connect approach ... your filter won't get a DNS name" was said of content filters (https://developer.apple.com/forums/thread/767285); that it applies here is inferred | **Yes** | Can block DoH flows, can't read inside them | The real new capability: per-app routing, proxy routing by hostname, DoH blocking |
| `NEPacketTunnelProvider` | Routes are IP lists, so it still needs a DNS hook | Per-app VPN is **MDM-only** ("The only way to configure Per-App VPN is by enrolling the device in ... MDM", NETunnelProviderManager docs) | No | **Rejected.** A Developer ID system extension can ship (TN3134), but "Only one enterprise VPN configuration can be enabled on the system at a time" (https://developer.apple.com/documentation/networkextension/netunnelprovidermanager; https://developer.apple.com/forums/thread/687862). Tailscale's NE tunnel (`io.tailscale.ipn.macsys`) holds it on the test Mac. GP's tunnel is not an NE packet tunnel, so GP would not be displaced (inferred) |
| Content filter, URL filter, `NEDNSSettingsManager` | Allow or block only, or a resolver setting | No | No | **Rejected.** They can't route |
| `NERelayManager` (macOS 14+) | Has `matchDomains` for domain-based routing | No | No | Not proposed. Needs a MASQUE relay server and an NE entitlement. Whether a loopback relay works is unverified |

**Shared costs of any NE path**
- **Packaging.** A system extension in `Contents/Library/SystemExtensions/`, plus two Developer ID provisioning profiles: the app's carries `system-extension.install`, the extension's carries `networking.networkextension`. The entitlement values take the `-systemextension` suffix, which Xcode does not know about (https://developer.apple.com/forums/thread/795579, https://developer.apple.com/forums/thread/737894).
- **AMFI.** On macOS 26 and later, AMFI kills a binary that carries these entitlements without a profile, even when notarized. We hit this on another project.
- **Signing.** Hand signing, because of "a known bug in Xcode's code-signing support" (https://developer.apple.com/forums/thread/815340).
- **No MDM needed on macOS** for the DNS proxy, transparent proxy or packet tunnel (TN3134: https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment). It is still user-approved, and corporate MDM can block it with `AllowUserOverrides=false` (https://developer.apple.com/documentation/devicemanagement/systemextensions). The current engine therefore has to stay as the fallback.
- **Coexistence on the test Mac** (per `systemextensionsctl list`):
  - Active network extensions: endpoint-security agents, Tailscale, GlobalProtect, and a consumer VPN's packet tunnels (installed, not connected).
  - One security agent's network extension is waiting for user approval, so it is not running.
  - GP has app-proxy configurations, all disabled.
  - Transparent proxies run in an order that is "an implementation detail" unless MDM sets `order` (https://developer.apple.com/forums/thread/820632).
  - A second DNS proxy, if GP enabled its own: Apple only "suspects" a flow hits both and says to test (https://developer.apple.com/forums/thread/672688).
  - Queries scoped to a VPN interface skip the DNS proxy (https://developer.apple.com/forums/thread/92042).
- **A broken DNS proxy takes all name lookups down.** The Little Snitch on macOS Tahoe report is unverified (the forum returned 403): https://forums.macrumors.com/threads/solution-no-internet-access-macos-tahoe-26-developer-beta.2458486. A kill switch is mandatory regardless.
- **Estimates (inferred):** DNS proxy about 2–3 weeks. Transparent proxy about 4–6 more weeks.

### D. Other credible options

- **D1. Fake IP plus a root utun** (Surge before 5.8, mihomo, sing-box; Tailscale `conn25` uses mapped "Magic IPs" in the same spirit).
  - **How:** answer matched names with addresses from `198.18.0.0/15`, route that one /15 into a utun the helper opens as root (`com.apple.net.utun_control`, sing-tun `tun_darwin.go:89-104`), map the fake IP back to the name, and open the real connection in user space over the chosen exit.
  - **Pros:** one static route, no race, and immune to shared CDN IPs, because the match is on the name, not the IP.
  - **Cons:** it needs a full user-space TCP/UDP stack. Fake IPs must never stay in caches after the app quits.
  - **Signal:** Tailscale is building conn25 to avoid "the 'too many routes' pitfall of app connector". It was still in progress as of 2026-02-04 (https://github.com/tailscale/tailscale/blob/main/feature/conn25/conn25.go, lines 4-7).
  - **Verdict:** the right next step if route-table growth or shared IPs become a real problem. Much more code than B.
- **D2. PF `rdr` to a local proxy that reads the SNI.** It separates names on shared IPs without NE. It needs PF anchor management, and it fails on Encrypted Client Hello (ECH). Not proposed now.

---

## 3. Permanent limits (hard vs impossible)

| Limit | Applies to | Hard or impossible |
|---|---|---|
| **Names on a shared IP follow the route.** Routing is keyed by destination IP, and the IP header carries no hostname | A, B, NE DNS proxy | Impossible **at the kernel-routing layer**, because the name is not in the packet the kernel routes. Hard overall: D1, D2 or the NE transparent proxy separate them at a higher layer |
| **Lookups that never reach the system resolver:** app DoH/DoT, Firefox with DoH forced on, Chrome "secure" mode, iCloud Private Relay, hardcoded IPs | A, B, NE DNS proxy | Hard. Firefox's default DoH can be turned off with the canary domain (https://support.mozilla.org/kb/canary-domain-use-application-dnsnet). Forced DoH needs flow interception (NE transparent proxy) to block it. Reading names inside DoH needs TLS interception, which is hard and invasive |
| **Hardcoded port-53 servers** | B only | Hard. A or an NE DNS proxy catches them |
| **A more specific resolver hides part of a wildcard** | B | Hard. Detect it on add, warn, or forward that sub-suffix too |
| **First-connection race** | A (always), B (only if `routeQueue` holds an answer past about 1 s) | Hard. B removes it in normal use |
| **Answers cached and connections opened before the wildcard was added** | All | Hard. Flushing on add fixes the cache. Open connections heal when they reconnect |
| **IPv4 only:** IPv6-only hosts under a wildcard become unreachable | B | Hard. It comes from the app's IPv4-only design (`RouteKernel.swift:312`), not from macOS |
| **Custom routes to HTTP or SOCKS proxies** | A, B | Hard. Needs the CONNECT-host path or a transparent proxy |
| **VPN Only under GlobalProtect** | All | Existing product rule (`RouteManager.swift:2008-2035`), not a limit of the mechanism |
| **MDM blocks system extensions** (`AllowUserOverrides=false`) | C | Impossible for us to override on that Mac. It is a policy the device owner controls. Fallback: B |
| **Only one enterprise VPN (packet tunnel) enabled at a time** | C (packet tunnel) | Impossible to run beside Tailscale's NE tunnel. It is an OS rule (NETunnelProviderManager docs) |
| **Per-app VPN** | C (packet tunnel) | Impossible without MDM. It is an OS rule. The transparent proxy is the non-MDM path to per-app routing |

---

## 4. What changes for users

- **Option B (ships first)**
  - No new prompts. It uses the helper that is already installed.
  - One helper upgrade, which brings the usual reinstall prompt once (XPC protocol bump).
  - No MDM impact.
  - Battery: one loopback query per matched name every 5 minutes or so, which is negligible (inferred).
  - **Visible change:** `scutil --dns` shows one extra resolver per wildcard.
  - **Behaviour change:** matched names get no IPv6 answers. Names under a wildcard are answered through the wildcard's upstream instead of a less specific resolver.
  - The Lookups page stays opt-in, because B doesn't need the capture.
- **Option A:** no prompts, but the capture runs whenever a wildcard exists. That needs new wording, because Lookups is sold as opt-in.
- **Option C (NE)**
  - A one-time approval in System Settings > General > Login Items & Extensions > Network Extensions, then a second prompt for the configuration.
  - On Macs where MDM sets `AllowUserOverrides=false`, it never activates unless MDM allow-lists team 624WUVM8B4. That is likely on many corporate Macs.
  - A broken extension can cut DNS for the whole Mac, so a kill switch is mandatory.
- **CLAUDE.md:** `CLAUDE.md:118` (and `docs/CHANGELOG.md:268`) should say wildcards are "hard: routing is per IP, so wildcards are resolved to IPs at lookup time", not "impossible".

---

## 5. Staged plan

1. **Spike (a Mac on macOS 26.6.1, then a Mac on macOS 27, GlobalProtect connected).** No product code yet.
   - Hand-write one resolver file pointing at `127.0.0.1` with `port 53530`, and run a stub forwarder.
   - Check:
     - (a) `scutil --dns` lists the file;
     - (b) `dscacheutil -q host -a name x.us5.datadoghq.com` reaches the stub on the non-53 port;
     - (c) `route -n get <ip>` shows the route before `curl` connects;
     - (d) the `en0`-bound upstream query is not taken over by GlobalProtect's extension;
     - (e) single route writes during a long browsing session don't tear GlobalProtect down;
     - (f) the files and routes survive a GlobalProtect reconnect;
     - (g) the file is still honoured under an encrypted-DNS profile;
     - (h) Chrome's lookups reach the stub.
   - Positive control: delete the route and watch (c) fail; remove the file and watch (b) fail.
2. **Ship B.** All three lists, at any depth.
   - Wildcard branch in `cleanDomain`, which strips `*` today through its character filter (`RouteManager.swift:5594-5596`).
   - Forwarder, safety guard, ledger, shadowing warning, learned routes in the existing sweep and reconcile, and the helper protocol bump.
   - Custom `suffix` rules with Direct routes or VPN routes pinned to one tunnel.
   - Firefox canary file.
   - Fix CLAUDE.md.
3. **Watch, then decide.** If shared-IP spill or route-table growth bites in real use, spike D1 (fake IP plus root utun). Still no entitlement.
4. **Gated on an explicit go, which lifts `MULTI-ROUTE-DESIGN.md:359`:** an NE transparent proxy as an opt-in Custom-mode engine for per-app routing, proxy routing by hostname and DoH blocking, with B as the fallback.
   - Spike it first beside endpoint-security agents, Tailscale and GlobalProtect.
   - Ship the profiles and hand signing in `scripts/sign-and-notarize.sh`.
   - Not recommended: an NE DNS proxy just for wildcards, because B already holds the answer until the route is in.

---

## 6. Sources

**Code** (`the repository`, main at `37404d1`)
- `CLAUDE.md:118`, `docs/CHANGELOG.md:268`
- `Helper/DNSCapture.swift:21,22,39,45-55,117-128`
- `Helper/HelperTool.swift:92,103-171,201-250,212-218,376`
- `Sources/VPNBypassCore/DNSResolver.swift:228`
- `RouteManager.swift:2008-2035,4913,4974-4982,5194-5251,5568-5599`
- `RouteKernel.swift:69-90,149,312,538`
- `HelperProtocol.swift:94,283-330`
- `ProxyForwarder.swift:746`
- `ConfigModel.swift:526,544`, `RouteModel.swift:39`, `RuleResolver.swift:69-71`, `RuleDestinationBuilder.swift:18,73`
- `docs/MULTI-ROUTE-DESIGN.md:148,359`
- Commit `c1ce9ef`

**Live reads on a test Mac (2026-10-29):** `scutil --dns`, `systemextensionsctl list`, `scutil --nc list`, `netstat -rn`, `/Library/Preferences/com.apple.networkextension.plist`, GP system extension `Info.plist` and entitlements, `man 5 resolver`, `man tcpdump`.

**macOS DNS and routing**
- https://keith.github.io/xcode-man-pages/resolver.5.html
- https://github.com/puma/puma-dev
- https://github.com/chromium/chromium/blob/main/net/dns/dns_config_watcher_mac.cc
- https://support.mozilla.org/kb/canary-domain-use-application-dnsnet

**Network Extension**
- https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- https://developer.apple.com/documentation/networkextension/nednsproxyprovider
- https://developer.apple.com/documentation/networkextension/netransparentproxyprovider
- https://developer.apple.com/documentation/networkextension/netunnelprovidermanager
- https://developer.apple.com/documentation/networkextension/nerelaymanager
- https://developer.apple.com/documentation/devicemanagement/systemextensions
- https://developer.apple.com/forums/thread/687862
- https://developer.apple.com/forums/thread/92042
- https://developer.apple.com/forums/thread/672688
- https://developer.apple.com/forums/thread/820632
- https://developer.apple.com/forums/thread/767285
- https://developer.apple.com/forums/thread/795579
- https://developer.apple.com/forums/thread/737894
- https://developer.apple.com/forums/thread/815340
- https://forums.macrumors.com/threads/solution-no-internet-access-macos-tahoe-26-developer-beta.2458486

**Other tools**
- https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/configure-warp/route-traffic/split-tunnels/
- https://docs.paloaltonetworks.com/globalprotect/administration/globalprotect-gateways/split-tunnel-traffic-on-globalprotect-gateways/split-dns
- https://tailscale.com/docs/reference/best-practices/app-connectors
- https://github.com/tailscale/tailscale/blob/main/net/dns/manager_darwin.go
- https://github.com/tailscale/tailscale/blob/main/feature/conn25/conn25.go
- https://manual.nssurge.com/features/enhanced-mode.html
- https://github.com/SagerNet/sing-tun/blob/main/tun_darwin.go

---

