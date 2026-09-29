# VPN Bypass

A macOS menu bar app that controls what goes through your VPN. Route specific domains and services *around* the VPN, force only some *through* it, or, in Custom mode, send each domain, service or subnet out a route you choose: direct, a specific VPN, an HTTP/SOCKS5 proxy, or a Tailscale peer.

Corporate VPNs often send all traffic through the tunnel, so streaming slows down, AirPlay and Chromecast break, and personal traffic crosses corporate infrastructure. VPN Bypass routes the services you pick straight to the internet and keeps business traffic on the VPN.

- [Getting started](getting-started.md): Homebrew, DMG, source, Xcode, requirements and permissions
- [Routing modes, routes and rules](routing.md): the settings for Bypass, VPN Only and Custom mode
- [Usage](usage.md): menu bar, settings tabs and the `vpnb` CLI
- [How it works](how-it-works.md): supported VPNs and detection logic
- [Coexistence with other VPNs and proxies](coexistence.md): what VPN Bypass touches when several VPNs or proxies run
- [Troubleshooting](troubleshooting.md): Gatekeeper, routes, the hosts file, DNS and proxy errors
- [Development and contributing](development.md): building and contributing
