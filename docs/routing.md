# Routing modes, routes and rules

## Why?

Corporate VPNs often route all traffic through the tunnel, which can cause issues:

- **Performance**: Streaming and messaging apps become slow or buffer constantly
- **Broken features**: Chromecast, AirPlay, and location-based features fail
- **Unnecessary load**: Non-business traffic clogs the VPN tunnel
- **Privacy**: Personal services don't need to go through corporate infrastructure

VPN Bypass intelligently routes selected services directly to the internet while keeping business traffic secure through VPN.

## Features

- 🎯 **Menu bar app** — quick access to status, mode, and controls
- 🧭 **Three routing modes** — **Bypass** *(default)*: everything uses the VPN **except** the domains you list. **VPN Only**: the inverse — everything goes **direct** except the domains you list, which are forced through the VPN. **Custom**: per-rule routing.
- 🌐 **Custom domains & built-in services** — add any domain, or toggle bundled service packs (Telegram, YouTube, WhatsApp, Spotify, Tailscale, and more)
- 🧩 **Custom rules & routes** — map each domain, suffix, IP/CIDR, service, or process to a specific route; first match wins
- 🔀 **Multiple egresses** — send traffic out the local gateway, a specific VPN interface (multi-VPN), an **HTTP/SOCKS5 proxy**, or a **Tailscale peer** used as an exit
- ⌨️ **`vpnb` CLI** — script the app over a user-only socket (status, routes, rules, mode)
- 🔄 **Auto-apply** — routes are (re)applied automatically as the VPN connects, disconnects, or the network changes
- 🔁 **Auto DNS refresh** — periodically re-resolves domains and updates routes as IPs rotate
- 📋 **Hosts file management** — optional DNS bypass via `/etc/hosts`
- 🔍 **VPN detection** — GlobalProtect, Cisco, Fortinet, Zscaler, Cloudflare WARP, Tailscale exit nodes, and more
- 🔔 **Notifications**, ✅ **route verification**, 🪵 **activity logs**, 💾 **import/export**, 🚀 **launch at login**
- 🔐 **Hardened privileged helper** — a small root helper performs the routing; it's cdhash-pinned to this app and uses **no Network Extension entitlements**

## Routing modes

VPN Bypass has three modes; switch anytime from the menu bar or Settings.

- **Bypass** *(default)* — everything uses the VPN as usual, and only the domains/services you list are routed *around* it to your regular connection. Best when your VPN carries all traffic but a few apps misbehave through it.
- **VPN Only** — the inverse: your regular connection is the default, and only the domains/services you list are forced *through* the VPN. Best for a mostly-direct machine with a few things tunneled.
- **Custom** — a per-rule engine: you define **routes** (egresses) and **rules** that map traffic to them. Rules are evaluated top-to-bottom, first match wins, with a pinned "everything else → default" rule. This is what unlocks multi-VPN, proxy, and Tailscale-peer routing.

**Bypass and VPN Only work exactly as they did in earlier versions** — if that's all you need, nothing changes. Custom mode is entirely opt-in.

### Routes and rules (Custom mode)

A **route** is a place traffic can exit:

| Route type | Traffic exits via |
|------------|-------------------|
| **Direct** | your local gateway (around the VPN) |
| **VPN** | a specific VPN interface — pick *which* tunnel when several are up (multi-VPN) |
| **HTTP / SOCKS5 proxy** | a local `127.0.0.1` listener that forwards to your proxy |
| **Tailscale peer** | out through a chosen Tailscale device used as an exit |

A **rule** maps traffic to a route by `domain`, `suffix`, `ip`, `cidr`, `service`, or `process`. The first matching rule wins; anything unmatched takes the **default** route. Direct and detected VPN routes appear automatically; proxy and Tailscale-peer routes are ones you add.

A proxy route's `127.0.0.1` listener holds your upstream proxy credentials, so it will not serve a client that cannot prove it is you. Any process on the machine can reach a loopback port, and macOS gives a TCP listener no way to see who connected, so the listener asks for a password instead. Use the **Copy exports** button on the route — it hands you the address with the credentials already in it:

```bash
export HTTPS_PROXY="http://vpnb:<secret>@127.0.0.1:18042"
```

The secret is generated once and kept in the app's config file, which only your account can read. Copy the exports again if you ever reset your config.
