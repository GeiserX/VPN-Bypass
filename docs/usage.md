# Usage

## Menu bar

Click the VPN Bypass mark in the menu bar: two lines and a bar, with an arrow head on the top line while routes are enforced. The dropdown shows:

- a pill that reads ON, WAITING (the app waits for a reconnected tunnel to hold before it re-applies routes), HELD BACK (the tunnel dropped right after several applies, so the app is not applying until it has held for 30 minutes), NO ROUTES (nothing installed), NOT SET UP (a fresh install with nothing configured), NOT ENFORCING (the helper is down) or OFF (no VPN);
- the VPN it found, one sentence on what your lists route, and two facts: when routes were last applied and whether any failed, and when DNS was checked and runs next. While the pill reads WAITING or HELD BACK, the header says how long is left instead;
- on a fresh install in Bypass mode, in place of everything down to the gear: the question "What should skip the VPN?", six common services with their switches, a row that opens Settings on the Services page, a field to add a site, and a line that offers VPN Only. Once a service is on or a site is on the list, the normal dropdown below takes its place at once;
- the Mode control, with Bypass, VPN Only and Custom in every mode. Picking another mode asks first, and the selection moves only after you confirm. Entering Custom turns your lists into rules here too;
- a field to add a domain to the current mode's list;
- the active services and routes;
- Refresh Routes, a Verify Routes icon, and a "…" menu with Verify Routes, Re-resolve DNS Now and Remove All Routes…, which asks before it removes anything;
- one line under the buttons with the result of the last apply, for example "62 routes applied 23 s ago, none failed";
- the gear that opens Settings.

![The dropdown in Bypass mode: VPN Connected over WireGuard, the pill reads ON, four services and two domains are routed around the VPN](images/screenshots/menu-bar.png){ width="340" }

## Settings

Click the gear icon to access settings. The pages are in a toolbar under the title bar, and which ones appear depends on the mode. Bypass: Domains, Services, General, Logs, Info. VPN Only: Domains, General, Logs, Info. Custom: Rules, Routes, General, Logs, Info.

The routing mode is the Mode menu at the right end of the title bar, for example "Mode Bypass". Picking another mode in it opens a sheet that lists the three modes, each with one sentence and what your lists hold for it ("4 services and 2 domains"). Nothing changes until you click Switch, and the title bar keeps showing the mode in use until then.

![The Services tab: built-in packs such as Telegram, YouTube, Spotify and WhatsApp, each with a switch, four of them on](images/screenshots/services.png){ width="580" }

![The Domains tab: two domains, each with its switch on, and the field to add another](images/screenshots/domains.png){ width="580" }

Domains: add custom domains, enable/disable them individually, see resolved IPs. The ⋯ menu next to the count holds Turn All On and Turn All Off.

Services: toggle built-in service packs (Telegram, YouTube, Spotify, …); each bundles known domains and IP ranges. The page lists the services that are on first, under On. The rest follow in the usual order, custom services before built-in ones. A service you switch on or off keeps its place until you next open the page, so a row never moves from under the pointer. That holds for a newly created service too, and for a service switched through `vpnb` while the page is open. The ⋯ menu next to the search field holds Turn All On… and Turn All Off, and both re-sort the list at once. Turn All On asks first when it would turn on more than five services ("Send 33 services around the VPN?"), with Cancel as the default button. Turn All Off does not ask.

Undo: a trash button removes a domain, a custom service with all its domains, a rule or a route on the first click, and leaves a line in the list such as "Removed news.ycombinator.com." with an Undo button. Turn All On and Turn All Off leave one too ("Turned off 4 services."). Undo, or Edit > Undo (⌘Z), puts the entry back where it was, with its switch as it was, and its routes come back with it. Undoing Turn All On or Turn All Off switches back only the entries it switched. While routes are still being applied, Undo is greyed out like the switches, and ⌘Z waits up to 10 seconds; if they are still running then, the change stays on the line to undo later. The line covers the last change only: the next delete or Turn All On/Off replaces it, and switching page or mode, or closing Settings, drops it.

Rules (Custom mode): the ordered rule list (first match wins) mapping domains/suffixes/IPs/CIDRs/services/processes to routes.

Routes (Custom mode): your egresses: auto-detected Direct + VPN links, plus any proxy or Tailscale-peer routes you add.

General: launch at login, auto-apply on connect, `/etc/hosts` management, route verification, notification preferences, import/export, and network status (VPN type, interface, gateway, Wi-Fi SSID).

Logs: the last 200 log entries, newest first, under Route Health. The segmented control above the list shows All, Warnings (warnings and errors) or Errors, and the search field keeps the entries whose text contains what you type, ignoring case and accents, with the match marked. A line above the list says how many entries match, for example "3 of 200 entries". Copy copies only the entries shown. Clear removes every entry, including the ones the filter hides.

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
vpnb domain.list
vpnb domain.add domain=example.com
vpnb domain.add domain=10.0.0.0/8 list=vpnOnly
vpnb domain.disable domain=example.com
vpnb domain.enable domain=example.com
vpnb domain.rm domain=example.com
vpnb service.list
vpnb service.list id=netflix
vpnb service.enable id=netflix
vpnb routes.active
vpnb routes.clear
vpnb refresh
vpnb dns.refresh
vpnb logs limit=20 level=error
```

- `domain.list` shows both lists, the Bypass list first; `list=bypass` or `list=vpnOnly` shows one. The VPN Only list also takes a CIDR.
- `domain.add` adds to the Bypass list unless you pass `list=vpnOnly`. It cleans and checks the value the way the Domains tab does. The Bypass list refuses an IP range such as `10.0.0.0/24` and takes a pasted link as its host name, and the VPN Only list refuses a malformed CIDR and a `/0` or `/1`. Adding a domain that is already on the list returns `already_exists`.
- `domain.rm`, `domain.enable` and `domain.disable` take `domain=` or `id=<uuid>`, and look in both lists unless you pass `list=`. When the same domain is on both lists, pass `list=bypass` or `list=vpnOnly`.
- `service.list id=netflix` shows one service with its domains and IP ranges. `service.disable` turns a service off.
- Enabling something that is already on, or disabling something already off, succeeds and changes nothing.
- A domain or service change is saved before `vpnb` returns. The routes for that entry are added or removed a moment later, and only while a VPN is connected and the app is in the mode that uses that list: Bypass mode for the Bypass list and the services, VPN Only mode for the VPN Only list. Run `vpnb routes.active` or `vpnb logs` to see them.
- `routes.active` lists the routes the app has installed; `source=<domain or service name>` keeps one source. `routes.clear` is Remove All Routes… in the dropdown's "…" menu, without the question, and the routes it removes come back at the next refresh, VPN reconnect or DNS refresh.
- `refresh` is the Refresh Routes button and `dns.refresh` is Settings > General > Refresh Now. Both start the work and return at once. `refresh` fails with `helper_not_ready` when the privileged helper is not ready.
- `vpnb status` prints the running app's version as `app: <version>` (the `appVersion` field on the socket).
- `logs` prints the newest entries first. It takes `limit` from 1 to 200 (default 50) and `level` as `info`, `success`, `warning` or `error`.
- An app older than 4.9.0 answers these commands with `unknown_command`.

The [MCP server](mcp-server.md) uses the same socket, so an AI agent can do all of this too.
