# How it works

## Supported VPN types

| VPN Client | Detection |
|------------|-----------|
| GlobalProtect | ✅ Full |
| Cisco AnyConnect | ✅ Full |
| OpenVPN | ✅ Full |
| WireGuard | ✅ Full |
| Fortinet FortiClient | ✅ Full |
| Zscaler | ✅ Full |
| Cloudflare WARP | ✅ Full |
| Pulse Secure | ✅ Full |
| Check Point | ✅ Full |
| Proton VPN | ✅ Full (kill switch on: routes have no effect, see [VPN kill switches](coexistence.md#vpn-kill-switches)) |
| AWS VPN Client | ✅ Full |
| Tailscale (exit node) | ✅ Full |
| Tailscale (mesh only) | ❌ Not VPN |

## Steps

1. **VPN Detection**: Monitors network interfaces to find the live tunnel, and names its VPN client from the process that owns it (the helper reads which process holds the tunnel). A client that is open but not connected does not name another client's tunnel; when the owner is unknown the tunnel is shown as "VPN"
2. **Gateway Detection**: Identifies your local gateway (Wi-Fi/Ethernet router)
3. **Route Management**: A small privileged helper adds/removes host routes to steer traffic per your mode — around the VPN (Bypass), through it (VPN Only), or to the route a rule selects (Custom). The helper is cdhash-pinned to this app and uses no Network Extension entitlements.
4. **Route Verification**: Path-checks up to 10 routed single addresses (a range has no one address to connect to), after an apply when that option is on or when the apply had failures, or from Verify Routes in the menu. See [Path check](#path-check)
5. **DNS Bypass**: Optionally adds entries to `/etc/hosts` to bypass VPN DNS

### When the helper needs an update

On launch the app asks the installed helper for its version. When the helper is older than the one in the app bundle, the app installs the new one.

**Without a password (helper 2.8.0 and newer).** The running helper already runs as root, so it installs the new one itself. The app sends it the path of the helper inside its bundle. The helper copies that file into `/Library/PrivilegedHelperTools` (only root can write there), checks the copy, renames it over its own file and exits; launchd starts the new file at once, because the launchd plist restarts the helper after a non-zero exit. The check: the copy is signed by our Developer ID team with the helper's identifier (`com.geiserx.vpnbypass.helper`), for every architecture, and the version in its signed Info.plist is newer than the running helper's. An unsigned file, a file signed by anyone else, another of our binaries, or an older or equal helper is refused and nothing changes. The installed file stays root-owned with mode 0544, as before. Nothing appears on screen and nothing changes in System Settings > Login Items.

The password installer below is still used when the installed helper is older than 2.8.0 (it does not have the call, so the update to 2.8.0 asks once), when the launchd plist in the app differs from the installed one (the helper replaces only its binary), and when the helper refuses or the new helper does not answer with the expected version. Each fallback is logged with its reason.

**With the administrator password.** That prompt can stay open for hours, for example on a locked screen, so the app does not wait for it:

- The older helper keeps working. Routes, `/etc/hosts`, the wildcard resolver files and the forwarder go through it, and the control socket (`vpnb`), the status passes and the menu answer as usual. Nothing already applied is removed because an update is pending.
- The prompt runs in an `osascript` child process, off the app's main thread, and closes after 10 minutes without an answer.
- Only a helper from 2.6.0 on is used this way: it has every call that keeps VPN Only from sending a listed name outside the tunnel (the wildcards and the VPN Only blocks). With an older helper the app waits for the update before it routes, as it always did, but the wait no longer freezes it.
- Settings > Status shows "Helper update to version X waiting for your password" while the prompt is open. If it is cancelled or times out, the app logs one line, Status says so with an **Update** button, and the app keeps using the older helper. It asks again on the next launch or when you click Update, never by itself. `vpnb status` shows the helper as running with the update pending while the prompt is open, and the update as not installed after a cancel or a timeout.
- When the new helper answers, the app uses it at once and sends it the wildcard list again, since the old helper removed its resolver files when it stopped. Kernel routes stay in place across the switch, and the app applies the routes once more (after any route pass already running) to put back a batch that reached the old helper while it was being replaced.

**What a new helper process starts without.** Whichever way the update lands (by itself or with the password), and when the Install button brings a helper back after a failed update, the new helper is a fresh process. Kernel routes, the VPN Only blocks (also kernel routes) and the `/etc/hosts` entries outlive it. Its wildcard list, resolver files and forwarder, and the DNS Lookups capture (`tcpdump`) do not. Once the new helper answers, the app sends the wildcard list again, applies the routes once more, and then starts the capture again when the Lookups page is watching or a Learn a Site window is open (never when it is off, and the setting is not changed). If the capture cannot start because the helper is still restarting, the app tries again every 3 seconds, and logs "DNS Lookups running again" when it starts. A helper that crashed is started again by launchd; the app's next wildcard drain (5 s) and capture drain (3 s) see that it serves nothing and set both up again.

**Why the helper is not moved into the app bundle (SMAppService).** macOS 13 lets an app register a daemon whose binary stays inside the app (`SMAppService.daemon` with `BundleProgram`), so replacing the app replaces the daemon's binary. We tested it on macOS 26.6 with a notarized, quarantined test app signed by our team, replaced the way `brew upgrade --cask` does it:

- After the bundle is replaced, the running daemon keeps its old binary until it exits. Asked to exit (non-zero), launchd starts the new binary from the bundle with no prompt and no new approval, and the approval survives the replacement. The background-item record holds the bundle id, team and a path relative to the bundle, no hash of the binary.
- Registering a daemon needs approval in System Settings > General > Login Items, and turning it on there asks for an administrator password. Every Mac that has our helper today would go through that once, and the helper would depend on that switch again, the dependency `RunAtLoad` removed (#25).
- The binary would live in the app bundle, which a Homebrew install leaves owned by the user, not root. In our test launchd started a replaced agent binary that was ad-hoc signed with another identifier. For daemons, Apple applies a launch constraint (a binary with a changed signing identifier was refused in a report on Apple's developer forums), but we could not confirm it for daemons without the approval click, and the helper's current file is root-owned.

Updating in place from the running helper needs no approval and no password once a helper has the call, keeps the root-owned file, and checks the same team signature the helper already requires of the app.

### VPN Detection Logic

> Running more than one VPN (e.g. a corporate client plus Tailscale), or local proxies? See
> **[Coexistence with other VPNs and proxies](coexistence.md)** for exactly what VPN Bypass will and will not
> touch — one tunnel is acted on, Tailscale is never selected, loopback is never routed.

The app intelligently detects corporate VPNs while avoiding false positives:

| Interface Type | IP Range | Detection |
|---------------|----------|-----------|
| **Corporate VPN** (GlobalProtect, Cisco, etc.) | `10.x.x.x`, `172.16-31.x.x` | ✅ Detected as VPN |
| **Cloudflare WARP** | `100.96-111.x.x` | ✅ Detected as VPN |
| **Tailscale** (mesh networking) | `100.64-127.x.x` | ❌ Not detected* |
| **Tailscale** (exit node active) | `100.64-127.x.x` | ✅ Detected as VPN |

**\*Tailscale in normal mode** only routes traffic to other Tailscale devices. It's not a "full VPN" because your regular internet traffic still goes through your normal connection. The app only considers Tailscale as a VPN when you're using an **exit node** (routing all traffic through another Tailscale device).

When more than one corporate tunnel is up, the log says which one the app acts on ("Multiple tunnels up (utun4, utun5) — using utun5"). The status pass runs every 30 seconds, so the line is logged once, and again only when the set of tunnels or the chosen one changes.

The detection also requires:
- The interface must have the `UP` flag (actually connected, not just configured)
- The interface must have an IPv4 address in a VPN range

## Routing priority

VPN Bypass wins over the VPN's routes by adding more specific ones, and macOS sends each packet by the route whose prefix matches the destination most closely (longest-prefix match). The one exception is a destination that already has a route of its own, which the helper rewrites in place (see below).

- **Bypass**: each address a listed domain or service resolves to gets a host route (a /32) through your local gateway, and each service IP range gets a network route through it. A /32 matches more closely than anything a VPN installs to capture traffic: its default route (`0.0.0.0/0`), the full-tunnel pair `0.0.0.0/1` + `128.0.0.0/1`, or a split route such as `10.0.0.0/8` that contains the address.
- **VPN Only**: the inverse. Listed addresses and ranges get routes through the VPN's gateway, and four catch-alls (`0.0.0.0/2`, `64.0.0.0/2`, `128.0.0.0/2`, `192.0.0.0/2`) send everything else through the local gateway. A /2 beats the VPN's default route and its /1 pair, and a listed /32 or range beats the /2. The app does not use the /1 pair itself, because WireGuard and OpenVPN install that exact pair to capture traffic, and claiming it would repoint the VPN's own routes. The catch-alls go in after the listed routes and come out first, so a listed destination never falls outside the tunnel during an apply. A listed range that covers a whole quarter (a /2) keeps that quarter in the tunnel: the app skips the catch-all inside it. The list refuses /0 and /1 because the VPN's own catch-alls use them.
- **Custom**: `ip`, `cidr`, `domain` and `service` rules get kernel routes in the same way, but only when their route is Direct or a VPN route pinned to one tunnel. A rule whose route is the primary VPN, a proxy or a Tailscale exit is served without a kernel route, so it shows in neither `vpnb routes.active` nor `netstat`. `suffix` rules work like wildcards (see [Wildcards](#wildcards)): with a Direct or pinned VPN route, each lookup under the suffix gets host routes. Only `process` rules install nothing: they name an app, which the routing table cannot tell apart, so [per-app routing](#per-app-routing) serves them, when it is on and their route is Direct. Otherwise the Rules page, `vpnb rule.list` (`servedBy: none` with an `inactiveReason` such as `perAppRoutingOff`) and `vpnb why` say why nothing serves them.

There is one kernel entry per destination. When a route for a destination already exists, for example one the VPN wrote, the helper rewrites that entry in place instead of adding a second one. A wildcard is the exception: it never takes over an address that already has another program's host route, which is how a VPN client pins its own server to the physical interface.

All of these routes are IPv4. The helper writes no IPv6 route, so IPv6 traffic to a listed name goes wherever the system's IPv6 routes send it.

### When the VPN connects, drops or changes the table

- **VPN drops**: in Bypass mode the routes through the local gateway stay, since they are still correct, and only routes through the gone VPN are removed. VPN Only removes all of its routes, catch-alls first, so traffic falls back to the normal default route rather than leaving through a stale catch-all.
- **VPN connects or reconnects**: the app applies the routes for the current mode again, after a short wait for the tunnel to settle (10 seconds, longer when the tunnel keeps dropping). It installs them from the addresses it resolved before, which are saved between launches, so the routes are in seconds after the wait ends. Then it looks every name up again in the background and adds or removes only the addresses that changed. Routes already in place are not written again. When nothing was resolved before, or a route from the saved addresses fails to install, the apply looks every name up first, which takes as long as the slowest lookups. In Bypass mode, when the kept routes were applied more recently than the DNS refresh interval and the configuration was not saved while the VPN was down, a reconnect writes nothing.
- **The VPN moves to another tunnel** (a second VPN connects and takes over the default route, or the VPN comes back on another `utun` without a drop the app sees): the routes are put back at once from the saved addresses, then every name is looked up again in the background, as on a connect. In Bypass mode the routes go through the local gateway, which did not change, so the helper rewrites nothing. In VPN Only, and for a Custom route pinned to one VPN, every route is rewritten to the new tunnel and none stays on the old one. A switch that comes while that background lookup still runs stops it and starts its own, so nothing is written twice; in Custom mode, where that lookup is a full apply, the switch waits for it to finish. A second switch within 10 seconds waits for the end of those 10 seconds. The same fallbacks as on a connect apply: an empty cache or a failed install from the cache looks every name up first. VPN Only under GlobalProtect stays refused on a switch too: no lookup, no route added.
- **A route vanishes** (the VPN client or the system deleted it): every 30 seconds, and on every network change, the app reads the kernel table and puts back any of its routes that is missing. This check looks for missing destinations only: a route that is still there but points somewhere else is not changed by it.

### Telling VPN Bypass's routes apart in `netstat -rn`

Every route the app adds carries the flags `RTF_UP`, `RTF_STATIC` and `RTF_PROTO1`, plus `RTF_GATEWAY` when it goes through a gateway address and `RTF_HOST` for a single address. `RTF_PROTO1` shows as `1` in the Flags column, and the app uses that mark itself to find its own routes after a crash:

```
Destination        Gateway            Flags               Netif Expire
203.0.113.10       192.168.1.1        UGHS1                 en0
198.51.100/24      192.168.1.1        UGS1c                 en0
```

`netstat -rn -f inet | awk '$3 ~ /1/'` lists them. Per-app routing's scoped default route shows as `default ... UGS1cIg en0` (the `I` is `RTF_IFSCOPE`), next to the system's own `default ... UGScg en0`; see [Per-app routing](#per-app-routing). Two catches: when the exact route the app wants is already in the table, the helper writes nothing, and when a destination already had another program's route (the VPN's, say), the helper rewrites that entry in place and it may keep that program's flags. Either way the destination can lack the `1` even though the app counts it as its own. `vpnb routes.active` (below) is the app's own list and covers those too. `netstat` shortens network destinations (`198.51.100/24` is `198.51.100.0/24`).

### Wildcards

A wildcard such as `*.example.com` cannot be a route, because routes are per address. The helper writes `/etc/resolver/example.com` pointing at its own DNS forwarder on `127.0.0.1:53530`. For each lookup under the suffix, the forwarder asks the DNS server the wildcard's route would use, installs a host route for each IPv4 address in the answer, and replies once those routes are in, so the route is normally in place before the app connects. A reply waits at most 1.5 seconds for its routes. If they are not in by then, a Bypass or Direct wildcard still returns the address with a 10-second TTL, and a connection made before its route lands goes through the VPN; a VPN Only or pinned-VPN wildcard withholds the address instead. These routes appear in `vpnb routes.active` with the source `*.example.com`. Only lookups that go through the macOS resolver reach the forwarder: a browser with its own DNS over HTTPS, or a program with a hardcoded resolver, gets addresses the app never sees. The forwarder keeps names in memory for one lookup only and never logs them.

A name under a wildcard that another program's resolver serves is left to that resolver. Tailscale publishes a resolver for its tailnet (`example-tailnet.ts.net`, at `100.100.100.100`), and a VPN may publish one for its company domains. Our resolver files come first in macOS's order, so with `*.ts.net` or `*.example-tailnet.ts.net` on a list, lookups for tailnet names reach the forwarder, and the DNS server the wildcard asks (the LAN's, say) does not know them. So the forwarder asks the resolver that serves the name, on its port and through its interface, passes its answer on unchanged (AAAA too) and learns no route from it. The most specific domain wins. Only resolvers for a domain count, never the default one, and never our own forwarder. A resolver whose servers the wildcard asks anyway keeps its names routed, so a VPN Only wildcard over the VPN's own split DNS works as before. The list comes from `scutil --dns` and is read again on every network change and every 30 seconds, and the log says which wildcards leave names to another resolver. Every other name under the wildcard is asked upstream and learned as before.

## Path check

Verify Routes and `vpnb why` ask which way an address actually leaves, not only whether it answers. For each address the app asks the routing table which interface it takes (the same question `route -n get` asks), opens a TCP connection to port 443 and reads the local address the system bound the connection to, which names the interface it left through. The result is right when that interface is the one the address's route points at (around the VPN in Bypass, into the tunnel in VPN Only, the rule's route in Custom, with a pinned tunnel read as it is numbered now) and the site answered on 443 that way; a refused connection counts as an answer. Otherwise the reason is "Went into utun4" (the wrong way), "No answer on 443 via en0" (the right way, nothing answering), or "Could not connect".

A name under a wildcard that the wildcard does not route is not judged by the wildcard's way. `vpnb why` asks of it what the forwarder asks (the same `WildcardSpec.delegation(for:)` and safety guard calls): a name whose domain another resolver serves, such as a tailnet name under `*.ts.net` that Tailscale's MagicDNS answers, gets that resolver's answer and no route, by design; a name whose addresses are all ones a wildcard never learns (`100.64.0.0/10`, private or reserved space) gets no route either. Such a name follows the system's own routing, a tailnet name through Tailscale's tunnel, so it is right whichever way it leaves as long as it answers: the verdict is `ok` when it answered, `noAnswer` when nothing did, never `wrongWay`. `--json` says why in `notRouted` (`ownResolver` with `resolverDomain`, or `addressNotRoutable`), and `expected` is absent. Verify Routes checks only the routes the app installed, and the forwarder installs none for these names, so it never checks them.

Each run also checks a control: the first of `192.0.2.1`, `198.51.100.1` and `203.0.113.1` (documentation addresses no site uses) that the app does not route. It must leave the other way: through the VPN in Bypass, around it in VPN Only, and through the VPN in Custom, since the app installs routes only for rules, so an address no rule claims follows the system's default route whatever the default route setting says. The control only needs its path, so the app closes that connection before it can complete. When the control leaves through another tunnel, or the VPN when it should go around it, the check cannot tell the two ways apart, and every result reads "Check broken". When it should take the VPN but leaves around every tunnel, the VPN is a split tunnel: it carries only some networks, and the default route stays on the physical interface. That is not broken. Each address is judged by its own way: a route into a tunnel (a pinned one, say) must leave through that tunnel, which the control did not; an address around the VPN leaves the right way, and `vpnb why` adds that an address the VPN does not carry would leave that way even without the entry. The entry still matters for an address inside one of the networks the VPN carries. An address no route covers (not on the list in Bypass, no rule in Custom, or while paused) follows the system's own routing, which then means the physical interface, or the tunnel for an address in one of the VPN's own networks. With no VPN connected there is one way out, so only the answer is checked, and the same holds when the app routes all three control addresses.

Both steps read the same routing table, so the check reports the route the system picks and whether the site answers that way. It cannot see a packet-filter `route-to` rule, a content filter, or a VPN that captures traffic below the routing table, such as a kill switch.

## Which app uses a route

A route belongs to a destination address, not to an application. Once VPN Bypass installs a route for `203.0.113.10`, every process on the Mac that sends to `203.0.113.10` uses it, whichever process caused the lookup and whether or not it is the app you listed. A wildcard route is created by a lookup, but the lookup reaches the forwarder through the macOS resolver, so it carries no process; every other route comes from your lists, apart from VPN Only's catch-alls. The routing table has no field that could record an app either. Routes cannot tell apps apart; only [per-app routing](#per-app-routing), which is off by default, can, and it does not tell apps apart with routes (its one route, a scoped default on the physical interface, serves every connection tied to that interface).

What a route does record is why it exists. `vpnb routes.active` gives each route a `source`:

| source | meaning |
|---|---|
| a domain, e.g. `example.com` | an address that domain resolved to (Bypass or VPN Only list, or a Custom `domain` rule) |
| a service name, e.g. `Example Service` | one of that service's addresses or IP ranges (a Custom `service` rule shows the service's id) |
| a range, e.g. `10.0.0.0/8` | an entry on the VPN Only list, or a Custom `ip` or `cidr` rule |
| `*.example.com` | an address learned by a wildcard lookup |
| `VPN Only catch-all` | one of VPN Only's /2 routes (up to four: a quarter that a listed range covers gets none) |

Several sources can share one destination when two names resolve to the same address. To find which process is talking to a routed address, for example to rule out a false leak alert, ask the system about live connections:

```bash
sudo lsof -nP -i @203.0.113.10        # processes with a connection to that address
nettop -n                             # live traffic per process and connection
route -n get 203.0.113.10             # the route and interface macOS would use for it now
```

## Per-app routing

Routes work per destination. Per-app routing works per app: an app on the Apps list (Bypass mode), or named in a `process` rule with the Direct route (Custom mode), reaches public IPv4 addresses over TCP around the VPN, whatever the destination's routes say. It is **off by default**, and with it off the app behaves exactly as it does without it. Turn it on in Settings > General > Per-app routing, or with `vpnb engine.on`.

It is a second engine beside the routes: a Network Extension, a transparent proxy that runs as a system extension. While it is on, macOS hands it every new outgoing TCP connection. For a connection from a listed app to a public IPv4 address, the extension opens its own connection, tied to the physical interface (Wi-Fi or Ethernet, so it cannot enter the tunnel), and copies the bytes both ways. Every other connection it hands back untouched, and it keeps its normal route, which may be the VPN:

- apps that are not listed;
- IPv6, UDP (QUIC, voice and video calls), and local, private and reserved addresses;
- connections an app binds to a network interface itself (they are counted as bound, and the group shows the count);
- the VPN client's own traffic (recognised by its code signature's team), VPN Bypass itself and Apple's system services;
- every connection while Pause is on, in VPN Only mode, and while the VPN sends every connection into its tunnel (`includeAllNetworks` or `enforceRoutes`, see [VPN kill switches](coexistence.md#vpn-kill-switches)): the app then sends the extension a policy that takes nothing.

What stays on kernel routes: everything else the app does. Domains, services, IP ranges and wildcards, every Custom rule that is not a `process` rule, VPN Only, `/etc/hosts` and the wildcard forwarder run the same with per-app routing on or off. Per-app routing does not match host names.

**The one route it adds: a scoped default on the physical interface.** A connection tied to an interface needs a route that belongs to that interface. VPNs that become the Mac's primary network service (GlobalProtect, for one) leave a scoped default route on Wi-Fi or Ethernet, and the extension uses it. VPNs that cover the internet with two half routes instead (`0.0.0.0/1` and `128.0.0.0/1`, as WireGuard's `wg-quick` and OpenVPN's `redirect-gateway def1` do) leave the primary interface with its ordinary default route only, and a connection tied to it finds nothing (`route -n get -ifscope en0 1.1.1.1` says "not in table"). So while per-app routing takes connections and the VPN is up, the helper adds the same route `route -n add -ifscope en0 default <router>` would, tagged as ours (`UGS1cIg` in `netstat -rn`). It serves only connections tied to that interface; the half routes still take everything else, so unlisted apps stay in the VPN. The helper adds it only when the interface has no scoped default already and its ordinary default goes through that router, and it never changes the ordinary default or the VPN's routes. It goes again when per-app routing turns off, pauses or stops taking connections (VPN Only, Pause, a kill switch), when the VPN goes down, when the interface or the router changes, when the app quits, and when the helper starts or stops; if the app stops asking (it renews the route with each 30-second policy push), the helper removes it after 150 seconds. One exception: if the interface stops carrying the Mac's default route while ours is there (the VPN became the primary service), macOS keeps a scoped default for it and may rely on ours, so the helper leaves it in place; the kernel drops it with the interface's address. With a helper older than 2.9.0 no route is added, and a listed app's first connections past such a VPN fail before it falls back to the VPN (below).

**The two approvals.** Turning it on asks twice. macOS first says the app "would like to use a new network extension": allow it in System Settings > General > Login Items & Extensions > Network Extensions, with your administrator password. That alert's own Open System Settings button does nothing on macOS 26 (the system daemon that shows it cannot open System Settings in your session), so use the Open System Settings button under the switch in Settings > General: it opens the Network Extensions list directly. Then it asks whether "VPN Bypass" may add proxy configurations: click Allow. If you say no to either, per-app routing stays off and nothing else changes. macOS runs the extension only when VPN Bypass is in the Applications folder.

**Managed Macs (MDM).** A profile from the Mac's administrator can forbid the extension (a system extension policy that does not allow it) or the proxy configuration. Settings > General then says it is blocked, and the routes keep working as before. An administrator who wants to allow it adds team ID `624WUVM8B4` with the extension `com.geiserx.vpn-bypass.proxy` to the system extension policy.

**When something fails.** If a connection tied to the interface cannot get out (no route there, the interface gone), the extension fails it at once, and after two such failures in a row it hands that interface's connections back for 30 seconds, so the app's next try goes through the VPN. When the scoped default route above is put in again (after a helper restart, say), those failures stop counting at once. The app renews the extension's policy every 30 seconds, and a policy lasts 2 minutes: if the app quits or crashes, the extension stops taking connections within 2 minutes and the listed apps use the VPN again. If the extension itself crashes, macOS holds every new TCP connection on the Mac for about 5 seconds, then lets them through without it; the app starts it once more, and turns per-app routing off if it crashes again within 10 minutes. Pause stands it down, but new connections still pass through the extension; only turning it off takes it out of their way.

**Updates.** After an app update the app asks macOS to replace the extension with the new version. On our test Mac that needed no approval; when macOS does ask, Settings > General says an update of the extension is waiting, and until it is allowed the listed apps use the VPN.

**Turning it off is the old way.** The switch in Settings > General, or `vpnb engine.off`, stops the extension, removes its proxy configuration (from then on no connection passes through it) and asks macOS to remove the extension itself, which needs your administrator password once. Afterwards nothing of it is left, and every app follows your routes as before. Turning it on again asks for both approvals again. When the app turns it off by itself (a second crash, a proxy configuration you did not allow, an imported configuration with the switch off), it only switches the configuration off, so no password prompt appears unasked; **Remove Extension**, under the switch, then removes the rest, as does `vpnb engine.remove`. Homebrew cannot remove a system extension, so turn per-app routing off before `brew uninstall`; [Troubleshooting](troubleshooting.md#remove-the-per-app-routing-extension) has the steps when the app is already gone.

**What it reports.** Settings > General and `vpnb engine.status` show the state (`off`, `awaitingExtensionApproval`, `awaitingConfigApproval`, `blocked`, `starting`, `active`, `paused`, `updateWaiting`, `failed`) and, per rule, how many connections went around the VPN and how many arrived bound. They hold counts only: the extension never logs or stores an app name, an address or a host name.
