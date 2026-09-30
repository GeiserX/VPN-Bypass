<p align="center">
  <img src="docs/images/banner.svg" alt="VPN Bypass banner" width="900"/>
</p>

<h1 align="center">VPN Bypass</h1>

<p align="center">
  A macOS menu bar app that decides which traffic goes through your VPN. Pick the services and domains that should skip it, or the few that must use it, and it keeps the routes right as the VPN reconnects and addresses change.
</p>

<p align="center">
  <a href="https://github.com/GeiserX/VPN-Bypass/releases"><img src="https://img.shields.io/github/v/release/GeiserX/VPN-Bypass?style=flat-square" alt="Release"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/GeiserX/VPN-Bypass/ci.yml?style=flat-square&logo=github&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GeiserX/VPN-Bypass?style=flat-square" alt="License"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/releases"><img src="https://img.shields.io/github/downloads/GeiserX/VPN-Bypass/total?style=flat-square&logo=apple&logoColor=white" alt="Downloads"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/stargazers"><img src="https://img.shields.io/github/stars/GeiserX/VPN-Bypass?style=flat-square&logo=github" alt="Stars"></a>
</p>

Corporate VPN clients send everything through the tunnel, so streaming stalls, AirPlay and Chromecast break, and personal traffic crosses the company network. Most clients lock their own split tunnelling, and a route added by hand is gone at the next reconnect or when a CDN moves. VPN Bypass adds the routes for you from a menu bar dropdown and puts them back every time the VPN or the network changes.

<table align="center">
  <tr>
    <td align="center"><img src="docs/images/screenshots/menu-bar.png" alt="The VPN Bypass dropdown in Bypass mode: VPN Connected, ON, four services and two domains routed around the VPN" width="300"></td>
    <td align="center"><img src="docs/images/screenshots/services.png" alt="The Settings window on the Services tab: 4 of 37 built-in packs enabled, Telegram, WhatsApp and YouTube switched on" width="400"></td>
  </tr>
  <tr>
    <td align="center"><sub>The dropdown in Bypass mode</sub></td>
    <td align="center"><sub>Settings, Services tab</sub></td>
  </tr>
</table>

## Features

- Three modes: Bypass sends the destinations you list around the VPN, VPN Only sends only them through it, and Custom routes each rule where you say, first match wins.
- 37 built-in service packs (Telegram, WhatsApp, YouTube, Netflix, Spotify, Zoom, GitHub and more) plus any domain, wildcard or subnet you add.
- In Custom mode a rule can exit direct, through a specific VPN when several are up, through an HTTP or SOCKS5 proxy, or through a Tailscale peer.
- Routes come back on their own when the VPN reconnects or the network changes, and domains are re-resolved as their addresses rotate.
- Detects GlobalProtect, Cisco AnyConnect, OpenVPN, WireGuard, FortiClient, Zscaler, Cloudflare WARP, Pulse Secure, Check Point and Tailscale exit nodes.
- Leaves Tailscale's own range, loopback and the other tunnels alone, so a mesh VPN and local proxies keep working next to it.
- `vpnb` scripts everything the app does over a socket only your account can open, and reads passwords from standard input, never from the command line.
- No kernel or system extension to approve: one small root helper does the routing, and only this app can talk to it.
- Optional `/etc/hosts` DNS bypass, route verification, notifications, launch at login, and config import and export.

## Quick start

```bash
brew tap geiserx/vpn-bypass
brew trust --cask geiserx/vpn-bypass/vpn-bypass
brew install --cask vpn-bypass
```

Then open VPN Bypass from Applications, approve the one admin prompt that installs the root helper, connect your VPN, and turn on a service in Settings > Services or type a domain into the dropdown. It worked when the pill in the dropdown reads ON and the menu bar mark shows its arrow. Needs macOS 13 or later; the DMG, building from source and the fix for "the app is damaged" are in [Getting started](https://geiserx.github.io/VPN-Bypass/getting-started/).

## Documentation

Everything is at [geiserx.github.io/VPN-Bypass](https://geiserx.github.io/VPN-Bypass/).

- [Getting started](https://geiserx.github.io/VPN-Bypass/getting-started/): Homebrew, DMG, source, and the first run
- [Routing modes](https://geiserx.github.io/VPN-Bypass/routing/): Bypass, VPN Only and Custom; routes and rules
- [Usage](https://geiserx.github.io/VPN-Bypass/usage/): the dropdown, the Settings tabs and the `vpnb` CLI
- [How it works](https://geiserx.github.io/VPN-Bypass/how-it-works/): supported VPN clients and how they are detected
- [Other VPNs and proxies](https://geiserx.github.io/VPN-Bypass/coexistence/): what it touches when several tunnels or proxies run
- [Troubleshooting](https://geiserx.github.io/VPN-Bypass/troubleshooting/): Gatekeeper, routes, DNS and proxy errors
- [Development](https://geiserx.github.io/VPN-Bypass/development/): build, test, contribute

What changed between versions is on the [Releases](https://github.com/GeiserX/VPN-Bypass/releases) page; planned work is in the [roadmap](ROADMAP.md).

## License

[GPL-3.0-or-later](LICENSE). Made possible by generous supporters: **Lee**.
