# Running alongside other VPNs and local proxies

VPN Bypass is rarely the only thing touching the network. A typical machine runs a corporate VPN
client, a mesh VPN such as Tailscale, and one or more local proxies at the same time. This page
states exactly what VPN Bypass will and will not do in that situation, so you can predict its
behaviour instead of discovering it.

The short version: **VPN Bypass acts on one tunnel — the corporate VPN — and leaves everything else
alone.**

---

## What VPN Bypass can and cannot control

VPN Bypass works by adding entries to the system routing table. That single fact explains most of
what follows.

**It can** decide, per destination IP, whether traffic goes through the VPN or around it.

**It cannot** decide anything per application. macOS only offers per-process network control through
a Network Extension, and this app deliberately does not use one — that is what keeps it installable
without special entitlements. So there is no way to say "this proxy goes direct, everything else
goes through the VPN". Rules are about *where traffic is going*, never about *what sent it*.

---

## Two VPNs at once

When several tunnels are up, VPN Bypass picks exactly one to act on, in this order:

1. **The tunnel carrying the default route.** This is direct evidence of which tunnel is actually
   moving traffic, so nothing outranks it.
2. **The tunnel it already chose**, as long as that is still valid. Under a split tunnel — the
   normal case for most corporate clients — several tunnels can look equally valid indefinitely.
   Sticking with the existing choice matters more than it sounds: every change of mind is treated as
   the VPN having changed, which rebuilds the whole route set, and repeatedly rebuilding the route
   set is what destabilises a tunnel in the first place.
3. **A fixed tie-break**, so the same machine in the same state always makes the same choice, and a
   restart never silently picks differently.

### Tailscale is never chosen

Tailscale is excluded from that selection entirely — including when it is acting as an exit node and
carrying the default route.

This is deliberate. Tailscale's traffic is not what any of the app's modes are meant to reroute, and
choosing it would be actively harmful: in **VPN Only** mode the app installs catch-all rules to force
traffic around the tunnel it selected. If it selected the wrong tunnel, the *other* tunnel's traffic
goes straight out. Excluding Tailscale removes that failure entirely.

If you want traffic to egress via a Tailscale peer, use a **Tailscale Peer** rule in Custom mode.
That is a separate, explicit mechanism.

### Addresses that are never touched

Some destinations are refused outright, in the privileged helper rather than the app — so the refusal
holds no matter what the app asks for:

| Destination | Why |
|---|---|
| `100.64.0.0/10`, or any prefix covering it | Tailscale's own range. Routing it would silently redirect or delete Tailscale's route. |
| `100.100.100.100` | Tailscale MagicDNS. |
| `127.0.0.0/8` | Loopback — see the proxy section below. |
| `169.254.0.0/16`, `224.0.0.0/4`, `255.255.255.255` | Kernel-reserved. |
| `0.0.0.0/0` | The whole internet in one rule; the app expresses this as two halves so it can be reasoned about and torn down safely. |

Individual addresses *inside* `100.64.0.0/10` are **not** blanket-refused, because that range is
shared with Zscaler and Cloudflare WARP, and blocking all of it would break legitimate rules for
those clients.

---

## Local proxies

A local proxy listens on loopback (`127.0.0.1:<port>`) and makes its own outbound connection to some
upstream server.

**The listener is never affected.** `127.0.0.0/8` is refused by the privileged helper, so no rule,
in any mode, can route loopback traffic. Applications talking to a local proxy keep working
regardless of what VPN Bypass is doing. This holds for any number of proxies on any number of ports.

**The upstream follows the mode you chose**, like any other destination:

- **Bypass mode** — only the destinations you list are routed around the VPN. A proxy's upstream is
  unaffected unless you list it.
- **VPN Only mode** — everything not listed goes direct, *including* proxy upstreams. This is the
  mode's entire purpose, but it is worth stating plainly: a proxy that was reaching its upstream
  through the VPN will stop doing so.
- **Custom mode** — each rule decides for itself.

If a proxy's upstream must stay inside the corporate VPN, add it as a **VPN Only** entry (or a
Custom rule targeting the VPN) so it is routed through the tunnel explicitly rather than left to the
catch-all.

---

## Checking what is actually happening

```sh
# Which tunnel currently carries the default route
route -n get default

# Every tunnel that is up
ifconfig | grep -E '^(utun|ipsec|ppp)[0-9]+'

# Tailscale's own addresses, to confirm which tunnel is Tailscale's
tailscale status --json | grep -A3 TailscaleIPs
```

The app's log names the tunnel it selected, and says so explicitly whenever more than one is up.
