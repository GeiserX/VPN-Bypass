<p align="center">
  <img src="docs/images/banner.svg" alt="VPN Bypass banner" width="900"/>
</p>

<h1 align="center">VPN Bypass</h1>

<p align="center">
  A macOS menu bar app that controls what goes through your VPN. Route specific domains and services
  <em>around</em> the VPN, force only some <em>through</em> it, or, in Custom mode, send each domain,
  service or subnet out a route you choose: direct, a specific VPN, an HTTP/SOCKS5 proxy, or a Tailscale peer.
</p>

<p align="center">
  <a href="https://github.com/GeiserX/VPN-Bypass/releases"><img src="https://img.shields.io/github/v/release/GeiserX/VPN-Bypass?style=flat-square&color=green" alt="Version"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/GeiserX/VPN-Bypass/ci.yml?style=flat-square&logo=github&label=CI" alt="CI"></a>
  <a href="docs/getting-started.md"><img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/stargazers"><img src="https://img.shields.io/github/stars/GeiserX/VPN-Bypass?style=flat-square&logo=github" alt="Stars"></a>
  <a href="https://github.com/GeiserX/VPN-Bypass/blob/main/LICENSE"><img src="https://img.shields.io/github/license/GeiserX/VPN-Bypass?style=flat-square" alt="License"></a>
</p>

Corporate VPNs often send all traffic through the tunnel, so streaming slows down, AirPlay and Chromecast break, and personal traffic crosses corporate infrastructure. VPN Bypass routes the services you pick straight to the internet and keeps business traffic on the VPN.

<p align="center"><img src="docs/images/screenshots/menu-bar.png" alt="VPN Bypass menu bar dropdown" width="300"></p>

## Features

- Menu bar app with status, mode and controls.
- Three routing modes: **Bypass** (default), **VPN Only**, and **Custom** per-rule routing where the first match wins.
- Custom domains plus built-in service packs (Telegram, YouTube, WhatsApp, Spotify, Tailscale and more).
- Egress through the local gateway, a specific VPN interface (multi-VPN), an HTTP/SOCKS5 proxy, or a Tailscale peer.
- `vpnb` CLI that scripts the app over a user-only socket.
- Re-applies routes when the VPN connects or the network changes, and re-resolves domains as IPs rotate.
- Detects GlobalProtect, Cisco, Fortinet, Zscaler, Cloudflare WARP, Tailscale exit nodes and more.
- Optional `/etc/hosts` DNS bypass, route verification, notifications, logs, import/export and launch at login.
- A small root helper does the routing. It is cdhash-pinned to this app and needs no Network Extension entitlements.

## Quick start

```bash
brew tap geiserx/vpn-bypass
brew trust --cask geiserx/vpn-bypass/vpn-bypass
brew install --cask vpn-bypass
```

Needs macOS 13 or later. The DMG download and building from source are in [Getting started](docs/getting-started.md). If macOS says the app is damaged, see [Troubleshooting](docs/troubleshooting.md).

## Documentation

The documentation is published as a site at [geiserx.github.io/VPN-Bypass](https://geiserx.github.io/VPN-Bypass/). The same pages on GitHub:

- [Getting started](docs/getting-started.md): Homebrew, DMG, source, Xcode, requirements and permissions
- [Routing modes, routes and rules](docs/routing.md)
- [Usage](docs/usage.md): menu bar, settings tabs and the `vpnb` CLI
- [How it works](docs/how-it-works.md): supported VPNs and detection logic
- [Coexistence with other VPNs and proxies](docs/coexistence.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Development and contributing](docs/development.md)
- [Changelog](docs/CHANGELOG.md) and [roadmap](ROADMAP.md)

## License

[GPL-3.0-or-later](LICENSE). Made possible by generous supporters: **Lee**.
