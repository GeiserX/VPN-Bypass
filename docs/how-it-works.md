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
| Tailscale (exit node) | ✅ Full |
| Tailscale (mesh only) | ❌ Not VPN |

## Steps

1. **VPN Detection**: Monitors network interfaces and running processes to detect VPN type
2. **Gateway Detection**: Identifies your local gateway (Wi-Fi/Ethernet router)
3. **Route Management**: A small privileged helper adds/removes host routes to steer traffic per your mode — around the VPN (Bypass), through it (VPN Only), or to the route a rule selects (Custom). The helper is cdhash-pinned to this app and uses no Network Extension entitlements.
4. **Route Verification**: Pings up to 10 routed single addresses (ping cannot test a range) to check they answer, after an apply when that option is on or when the apply had failures, or from Verify Routes in the menu
5. **DNS Bypass**: Optionally adds entries to `/etc/hosts` to bypass VPN DNS

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

The detection also requires:
- The interface must have the `UP` flag (actually connected, not just configured)
- The interface must have an IPv4 address in a VPN range

## Routing priority

VPN Bypass never changes the VPN's own routes to win. It adds more specific ones, and macOS sends each packet by the route whose prefix matches the destination most closely (longest-prefix match).

- **Bypass**: each address a listed domain or service resolves to gets a host route (a /32) through your local gateway, and each service IP range gets a network route through it. A /32 matches more closely than anything a VPN installs to capture traffic: its default route (`0.0.0.0/0`), the full-tunnel pair `0.0.0.0/1` + `128.0.0.0/1`, or a split route such as `10.0.0.0/8` that contains the address.
- **VPN Only**: the inverse. Listed addresses and ranges get routes through the VPN's gateway, and four catch-alls (`0.0.0.0/2`, `64.0.0.0/2`, `128.0.0.0/2`, `192.0.0.0/2`) send everything else through the local gateway. A /2 beats the VPN's default route and its /1 pair, and a listed /32 or range beats the /2. The app does not use the /1 pair itself, because WireGuard and OpenVPN install that exact pair to capture traffic, and claiming it would repoint the VPN's own routes. The catch-alls go in after the listed routes and come out first, so a listed destination never falls outside the tunnel during an apply. A listed range that covers a whole quarter (a /2) keeps that quarter in the tunnel: the app skips the catch-all inside it. The list refuses /0 and /1 because the VPN's own catch-alls use them.
- **Custom**: `ip`, `cidr`, `domain` and `service` rules get kernel routes in the same way, but only when their route is Direct or a VPN route pinned to one tunnel. A rule whose route is the primary VPN, a proxy or a Tailscale exit is served without a kernel route, so it shows in neither `vpnb routes.active` nor `netstat`. `suffix` rules work like wildcards (see [Wildcards](#wildcards)): with a Direct or pinned VPN route, each lookup under the suffix gets host routes. Only `process` rules install nothing.

There is one kernel entry per destination. When a route for a destination already exists, for example one the VPN wrote, the helper rewrites that entry in place instead of adding a second one. A wildcard is the exception: it never takes over an address that already has another program's host route, which is how a VPN client pins its own server to the physical interface.

All of these routes are IPv4. The helper writes no IPv6 route, so IPv6 traffic to a listed name goes wherever the system's IPv6 routes send it.

### When the VPN connects, drops or changes the table

- **VPN drops**: in Bypass mode the routes through the local gateway stay, since they are still correct, and only routes through the gone VPN are removed. VPN Only removes all of its routes, catch-alls first, so traffic falls back to the normal default route rather than leaving through a stale catch-all.
- **VPN reconnects**: the app applies the routes for the current mode again, after a short wait for the tunnel to settle. In Bypass mode, when the kept routes were applied more recently than the DNS refresh interval, a reconnect writes nothing.
- **A route vanishes** (the VPN client or the system deleted it): every 30 seconds, and on every network change, the app reads the kernel table and puts back any of its routes that is missing. This check looks for missing destinations only: a route that is still there but points somewhere else is not changed by it.

### Telling VPN Bypass's routes apart in `netstat -rn`

Every route the app adds carries the flags `RTF_UP`, `RTF_STATIC` and `RTF_PROTO1`, plus `RTF_GATEWAY` when it goes through a gateway address and `RTF_HOST` for a single address. `RTF_PROTO1` shows as `1` in the Flags column, and the app uses that mark itself to find its own routes after a crash:

```
Destination        Gateway            Flags               Netif Expire
203.0.113.10       192.168.1.1        UGHS1                 en0
198.51.100/24      192.168.1.1        UGS1c                 en0
```

`netstat -rn -f inet | awk '$3 ~ /1/'` lists them. Two catches: when the exact route the app wants is already in the table, the helper writes nothing, and when a destination already had another program's route (the VPN's, say), the helper rewrites that entry in place and it may keep that program's flags. Either way the destination can lack the `1` even though the app counts it as its own. `vpnb routes.active` (below) is the app's own list and covers those too. `netstat` shortens network destinations (`198.51.100/24` is `198.51.100.0/24`).

### Wildcards

A wildcard such as `*.example.com` cannot be a route, because routes are per address. The helper writes `/etc/resolver/example.com` pointing at its own DNS forwarder on `127.0.0.1:53530`. For each lookup under the suffix, the forwarder asks the DNS server the wildcard's route would use, installs a host route for each IPv4 address in the answer, and replies once those routes are in, so the route is normally in place before the app connects. A reply waits at most 1.5 seconds for its routes. If they are not in by then, a Bypass or Direct wildcard still returns the address with a 10-second TTL, and a connection made before its route lands goes through the VPN; a VPN Only or pinned-VPN wildcard withholds the address instead. These routes appear in `vpnb routes.active` with the source `*.example.com`. Only lookups that go through the macOS resolver reach the forwarder: a browser with its own DNS over HTTPS, or a program with a hardcoded resolver, gets addresses the app never sees. The forwarder keeps names in memory for one lookup only and never logs them.

## Which app uses a route

A route belongs to a destination address, not to an application. Once VPN Bypass installs a route for `203.0.113.10`, every process on the Mac that sends to `203.0.113.10` uses it, whichever process caused the lookup and whether or not it is the app you listed. A wildcard route is created by a lookup, but the lookup reaches the forwarder through the macOS resolver, so it carries no process; every other route comes from your lists. The routing table has no field that could record an app either. VPN Bypass does not use a Network Extension, by design, so it cannot tell apps apart; `process` rules are accepted but install nothing.

What a route does record is why it exists. `vpnb routes.active` gives each route a `source`:

| source | meaning |
|---|---|
| a domain, e.g. `example.com` | an address that domain resolved to (Bypass or VPN Only list, or a Custom `domain` rule) |
| a service name, e.g. `Example Service` | one of that service's addresses or IP ranges (a Custom `service` rule shows the service's id) |
| a range, e.g. `10.0.0.0/8` | an entry on the VPN Only list, or a Custom `ip` or `cidr` rule |
| `*.example.com` | an address learned by a wildcard lookup |
| `VPN Only catch-all` | one of VPN Only's four /2 routes |

Several sources can share one destination when two names resolve to the same address. To find which process is talking to a routed address, for example to rule out a false leak alert, ask the system about live connections:

```bash
sudo lsof -nP -i @203.0.113.10        # processes with a connection to that address
nettop -n                             # live traffic per process and connection
route -n get 203.0.113.10             # the route and interface macOS would use for it now
```
