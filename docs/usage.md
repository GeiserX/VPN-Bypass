# Usage

## Menu bar

Click the VPN Bypass mark in the menu bar: two lines and a bar, with an arrow head on the top line while routes are enforced. The dropdown shows:

- the VPN it found and its type, and a pill that reads ON, NO ROUTES (nothing configured), NOT ENFORCING (the helper is down) or OFF (no VPN);
- the Mode switch, Bypass or VPN Only; in Custom mode a button back to Bypass;
- a field to add a domain to the current mode's list;
- the active services and routes;
- Refresh Routes, Clear and Verify Routes, and the gear that opens Settings.

![The dropdown in Bypass mode: VPN Connected over WireGuard, the pill reads ON, four services and two domains are routed around the VPN](images/screenshots/menu-bar.png){ width="340" }

## Settings

Click the gear icon to access settings. The tabs depend on the mode. Bypass: Domains, Services, General, Logs, Info. VPN Only: Domains, General, Logs, Info. Custom: Rules, Routes, General, Logs, Info.

![The Services tab: built-in packs such as Telegram, YouTube, Spotify and WhatsApp, each with a switch, four of them on](images/screenshots/services.png)

![The Domains tab: two domains, each with its switch on, and the field to add another](images/screenshots/domains.png)

Domains: add custom domains, enable/disable them individually, see resolved IPs.

Services: toggle built-in service packs (Telegram, YouTube, Spotify, …); each bundles known domains and IP ranges.

Rules (Custom mode): the ordered rule list (first match wins) mapping domains/suffixes/IPs/CIDRs/services/processes to routes.

Routes (Custom mode): your egresses: auto-detected Direct + VPN links, plus any proxy or Tailscale-peer routes you add.

General: launch at login, auto-apply on connect, `/etc/hosts` management, route verification, notification preferences, import/export, and network status (VPN type, interface, gateway, Wi-Fi SSID).

Logs: recent activity for debugging.

Info: version and helper status.

## Command-line control (`vpnb`)

A bundled `vpnb` CLI drives the same routing the GUI does, over a user-only UNIX socket, for scripting or a headless Mac. It needs no extra privilege (the app already holds it).

`vpnb` ships inside the app bundle (`VPN Bypass.app/Contents/MacOS/vpnb`). Installing via the Homebrew **tap** (`brew tap geiserx/vpn-bypass && brew install --cask vpn-bypass`) symlinks it onto your `PATH`. With a manual DMG install, call it by its full path (`"/Applications/VPN Bypass.app/Contents/MacOS/vpnb"`) or symlink it onto your `PATH` yourself.

```bash
vpnb status                                   # current mode, routes, schema/version
vpnb mode mode=custom                         # switch modes: bypass | vpnOnly | custom
vpnb route.add name=work type=socks5 host=127.0.0.1 port=1080
vpnb rule.add match=suffix pattern=example.com routeId=<uuid>
vpnb route.list ; vpnb rule.list
```

Secrets are never passed on the command line (argv is world-visible via `ps`). Pass the bare token `pass:-` and pipe the password on stdin:

```bash
read -rs PASS && printf '%s' "$PASS" | vpnb route.set id=<uuid> pass:-
```

Set `VPNB_SOCKET` to override the socket path (default: `~/Library/Application Support/VPNBypass/control.sock`).

### Domains, services and logs (4.9.0 and later)

From VPN Bypass 4.9.0, `vpnb` also reaches the Bypass and VPN Only modes: the two domain lists, the services, the routes the app has installed, the refresh buttons and the log.

```bash
vpnb domain.list                        # both lists; list=bypass or list=vpnOnly
vpnb domain.add domain=example.com      # the Bypass list
vpnb domain.add domain=10.0.0.0/8 list=vpnOnly
vpnb domain.disable domain=example.com  # domain.enable turns it back on
vpnb domain.rm domain=example.com       # or id=<uuid>
vpnb service.list                       # id=netflix adds domains and IP ranges
vpnb service.enable id=netflix          # service.disable turns it off
vpnb routes.active                      # source=<domain or service name> filters
vpnb routes.clear                       # the Clear button in the dropdown
vpnb refresh                            # the Refresh Routes button
vpnb dns.refresh                        # Settings > General > Refresh Now
vpnb logs limit=20 level=error          # newest first
```

- `domain.list` without `list=` shows the Bypass list first. The VPN Only list also takes a CIDR.
- `domain.add` cleans and checks the value the way the Domains tab does. The Bypass list refuses a value with `/`, and the VPN Only list refuses a malformed CIDR and a `/0` or `/1`. Adding a domain that is already on the list returns `already_exists`.
- `domain.rm`, `domain.enable` and `domain.disable` look in both lists unless you pass `list=`. When the same domain is on both lists, pass `list=bypass` or `list=vpnOnly`.
- Enabling something that is already on, or disabling something already off, succeeds and changes nothing.
- A domain or service change is saved before `vpnb` returns. The routes for that entry are added or removed a moment later, and only while a VPN is connected. Run `vpnb routes.active` or `vpnb logs` to see them.
- `refresh` and `dns.refresh` start the work and return at once. `refresh` fails with `helper_not_ready` when the privileged helper is not ready.
- Routes removed by `routes.clear` come back at the next refresh, VPN reconnect or DNS refresh.
- The `status` result carries the running app's version as `appVersion`.
- `logs` takes `limit` from 1 to 200 (default 50) and `level` as `info`, `success`, `warning` or `error`.
- An app older than 4.9.0 answers these commands with `unknown_command`.

The [MCP server](mcp-server.md) uses the same socket, so an AI agent can do all of this too.
