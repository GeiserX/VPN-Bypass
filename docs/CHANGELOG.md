# Changelog

Releases after 3.1.13 are recorded on the [Releases page](https://github.com/GeiserX/VPN-Bypass/releases); this file is not updated.

All notable changes to VPN Bypass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Switches have names for VoiceOver, and the dropdown has keyboard shortcuts.** Every switch was an unnamed toggle shrunk with a scale effect, so VoiceOver read each one as "switch, on" with no name, and a list of 37 services was 37 identical switches. The scale effect shrank the drawing but not the space the switch took, so the click target was larger than the switch you saw. Every switch, in the dropdown and on the Domains, Services, Rules, Routes and General pages, now carries its row's name and uses the native small switch, which draws at the size it takes. Icon-only buttons say what they do and to which row ("Delete en.wikipedia.org", "Edit Work Tools"). With the dropdown open, ⌘, opens Settings and ⌘Q quits, and while a VPN is connected ⌘R refreshes routes, once per press even when held; the "…" menu now also holds Refresh Routes, Open Logs, Settings… and Quit VPN Bypass, each with its shortcut, and the gear's and power button's tooltips name theirs. ⌘F puts the cursor in the Services page's search field. The new text is in English, Spanish and French.
- **The app shows what `vpnb` and AI agents changed.** The control socket, which `vpnb` and the [MCP server](mcp-server.md) use, runs the same code as the app's own buttons and writes the same log lines, so a domain an agent added just appeared in the list and nothing said where it came from. Every log line written while the app serves a socket request, and by the work that request starts, now ends in "via the command line" on the Logs page, in Copy and in the log file. The dropdown's foot names the last change made that way: "Last change: added en.wikipedia.org via the command line, 2 min ago". Clicking it opens Logs showing only those lines. A change you make in the app removes the line. After a socket `routes.clear` it also goes once the route count changes, since "removed all routes" is no longer true then. Two requests that run at the same time are not named, since each could see the other's change. The old "Control: 'domain.add' applied via the command line" line now reads "Control: 'domain.add' applied", with the tag. The socket's replies, `status` included, are unchanged. The new text is in English, Spanish and French.
- **Settings has a Status page that says whether the app is working right now.** The answer was spread over two pages: the helper's state was the third of ten cards on General, the network status and the tunnel diagnostics sat at the bottom of it, and the route counts and the DNS schedule were in a Route Health block on Logs. Status is now the first page in every mode, and Settings opens on it. A line at the top gives the verdict and the dropdown's own sentence ("Working. 4 services and 2 domains skip the VPN. 62 routes applied 23 s ago, none failed."). Under it are the helper, with its Install, Update or Retry button and a red box when it is not ready; the VPN, the normal connection and the default route; what the last apply did, what the routes come from and the last Verify, with a Verify button; the DNS resolver and refresh schedule, with Refresh Now; each tunnel with one plain sentence in place of the old badges, and the Act on menu; and the three newest warnings, with Show in Log, which opens Logs on Warnings. General keeps settings only, and Logs keeps the log. The dropdown's Fix… button opens the Status page. The new text is in English, Spanish and French.
- **The Logs page has a level filter and a search field.** Settings > Logs was one list of up to 200 entries, newest first, so a warning or an error scrolled past among routine lines, and the only tools were Copy and Clear. A segmented control above the list now shows All, Warnings or Errors. Warnings includes errors, so one click shows everything that needs a look. A search field keeps the entries whose text contains what you type, ignoring case and accents, and marks the match. A line says how many entries match ("3 of 200 entries"), and an empty result says what found nothing ("No errors."). Copy copies only the entries shown; Clear still removes every entry. The new text is in English, Spanish and French.
- **A fresh install asks what should skip the VPN, in the dropdown.** It used to show an amber NO ROUTES pill and a line that sent you to Settings with no button to get there. With nothing configured in Bypass mode, the pill now reads NOT SET UP in grey, and the dropdown asks "What should skip the VPN?" over a list of six common services (Telegram, WhatsApp, YouTube, Zoom, Microsoft Teams, Spotify), each with the Services page's switch. A switch applies at once. "All 37 services…" opens Settings on the Services page, a field adds a site and says why when it refuses one, and a line offers VPN Only instead, behind the same question the Mode control asks. Once a service is on or a site is on the list, the dropdown shows its normal view at once. Zoom and Teams now have their own symbols instead of a globe. The new text is in English, Spanish and French.
- **Scripts can now drive Bypass and VPN Only mode over the control socket.** Until now the socket and `vpnb` only reached Custom mode's routes and rules, so a script or an MCP server could not touch the two domain lists or the services. New verbs: `domain.list`, `domain.add`, `domain.rm`, `domain.enable` and `domain.disable` for both lists; `service.list`, `service.enable` and `service.disable`; `routes.active` for the kernel routes the app has installed; `routes.clear`, `refresh` and `dns.refresh`, which do what Remove All Routes…, Refresh Routes and Refresh DNS now do; and `logs` for recent log lines. `status` now reports the app version. Each verb calls the same code as its button, so the edit changes the kernel routes for that one entry only. Bad or duplicate input gets an error code (`invalid_args`, `already_exists`, `not_found`, `helper_not_ready`) where the GUI would have ignored it.
- **The Domains tab says what an add did.** The add field used to empty after Return whatever happened, so a duplicate or a value with nothing usable in it looked like a success. A failed add now keeps the text, outlines the field in red and says why in one line under it ("en.wikipedia.org is already on your Bypass list."). A saved one names what went in, and says so when the app rewrote the input: "Added news.ycombinator.com, from the link you pasted." The quick-add field in the menu bar dropdown stays open with the same line when an add is refused, instead of closing as if it had worked. The line is in English, Spanish and French. `vpnb domain.add` makes the same decision, from the same code.
- **An edit to a list the current mode does not route leaves the kernel alone.** The settings window shows only the list the current mode routes, but the socket can edit either one. A Bypass entry or a service changed while VPN Only or Custom is active, or a VPN Only entry removed in Bypass mode, no longer touches the kernel, and removing a Bypass entry there keeps a pending DNS retry of the same name, which belongs to a Custom rule. Without this, a script could install a bypass route that VPN Only or Custom does not want, or delete a route that belongs to an entry of the same name on the other list.

### Fixed
- **The dropdown's quick-add in Custom mode saves an IP range as a range rule.** Typing `10.0.0.0/24` in the dropdown's add field in Custom mode saved a domain rule for the one host `10.0.0.0`, because the field cleaned every value as a link and cut it at the `/`. A range now becomes a CIDR rule on the Direct route, the rule the Rules page saves for the same range, and a name or a pasted link still becomes a domain rule for its host. A range the Rules editor would refuse, such as `10.0.0.0/33` or a /0 or /1 catch-all, is refused here too: the field stays open with the text and one line under it that says why, as it does in Bypass mode, and nothing is saved. A value with nothing usable in it, such as `!!!`, now gets that line too instead of the field closing as if it had worked. So does a value that already has a rule: on Direct the line says so, and on another route, such as your VPN or a proxy, it names that route and says to change the rule on the Rules page, since the first matching rule wins and a second rule on Direct would do nothing. Nothing is saved in either case. The lines are in English, Spanish and French.
- **Settings > Status's Addresses owned row names VPN Only's catch-alls apart.** With two entries on the VPN Only list, Routed read 2 and Addresses owned, under Tunnels, read 6, because the row counted the 4 catch-all routes the app installs to send everything else direct as addresses. The row now reads "2, plus 4 catch-alls", and "0, plus 4 catch-alls" when the list is empty. It still counts the routes in the kernel that carry the app's tag, by the rule the routes card and Routed use, so the first number matches Routed while the kernel holds what the app installed. Bypass and Custom show one number, as before. The new text is in English, Spanish and French.
- **A built-in service that an update adds with the name of one of your custom services no longer shares its routes.** The app tracks a service's routes by its name. If a new version added a built-in service, or renamed one, to a name a custom service already had, ignoring case and spaces, both routed under that name once you turned the built-in one on, and removing one removed the other's routes. On launch the app now turns the built-in service off while the custom one has its name. Its switch, Turn All On and `vpnb service.enable` leave it off, and `vpnb` returns `already_exists`. Your custom service keeps its name, its switch and its routes. Its row on the Services page shows the editor's red line asking for another name, and the built-in row says which custom service to rename. Once you rename it, the built-in service turns on as usual. In VPN Only and Custom modes, deleting a custom service no longer takes routes of the same name out of the kernel: those belong to a VPN Only entry, the VPN Only catch-all or a rule, since services route only in Bypass. The new line is in English, Spanish and French.
- **Re-rendering the UI proposal images crops the old screenshots again.** 22 of the mockups in `docs/design/proposals/ui/` build their "before" half by cropping the screenshots in `docs/images/screenshots/` at fixed offsets. Those files now show the 5.0 app, so running `render.sh` again would have cropped the wrong picture at the old offsets. The mockups now crop their own copies of the screenshots from `ddd1cb0`, in `docs/design/proposals/ui/before/`. The committed images are unchanged.
- **The Rules page's badges and route chips, the proxy test result and the route check's failure reason are in Spanish and French.** These texts went through a plain `String`, which SwiftUI's `Text` shows as typed, so a Mac set to Spanish or French saw them in English: the match badges ("DOMAIN", "SUFFIX", "SERVICE", "PROCESS"), the route chip of a rule with no route ("Choose Route") or sent direct ("Direct"), the General page's SOCKS5 proxy test result ("Connection timeout", "Connected to …") and the reason a route check failed ("Ping timed out", "Host unreachable"). A VPN the app does not recognise showed as "Unknown VPN" in the rule chips, on the Routes page, in the dropdown, in Settings > Status's tunnel list and in both VPN pickers; it now shows "VPN". The Routes page's type badge and status line ("Direct", "primary VPN", "direct") are looked up too. [`scripts/check-localizations.py`](https://github.com/GeiserX/VPN-Bypass/blob/main/scripts/check-localizations.py) now also fails when the English, Spanish or French file has a key that no source file uses. A translated string changed back to a plain literal leaves its key unused when no other source uses that key, so the check catches it. A key used in several places, such as "Direct" or "VPN", stays in use, so the labels above that share one have a test in `LocalizationCoverageTests` instead. The 43 keys it found unused, left from screens 5.0 removed, are gone from all three files.
- **`vpnb domain.rm`, `domain.enable` and `domain.disable` take the link that `domain.add` took.** `vpnb domain.add domain=example.com/page` saves `example.com` on the Bypass list, but removing, enabling or disabling it with the same value answered "malformed CIDR", because those three verbs treated any `/` without `https://` in front as a broken IP range. They now read the value by the rule `domain.add` uses: on the Bypass list a link is its host and an IP range is refused, and with `list=vpnOnly` a value with a `/` must be a CIDR. Without `list=`, a link is looked up on both lists by its host, so a domain on both lists still asks for `list=`. A malformed range such as `10.0.0.0/33` is still refused everywhere and never cut down to the host `10.0.0.0`. The [MCP server](mcp-server.md)'s `remove_domain` and `set_domain_enabled` get the same answers.
- **A proxy route's upstream address stays on one line on the Routes page.** The card put "Upstream" and "Listening on" side by side, so an upstream longer than about 17 characters broke mid-address: `198.51.100.20:1080` drew as `198.51.100.20:108` with the `0` on the next line, and most host names are longer than that. The listening address now has its own line under the upstream, which leaves room for an upstream such as `2001:db8:85a3::8a2e:370:7334:1080` or `egress-proxy.eu-west-1.corp.example.com:3128`. An upstream too long even for its own line is cut in the middle with "…", never wrapped, and its tooltip shows the whole address.
- **The screenshots in the README and the docs show the 5.0 dropdown and Settings window.** Five of the seven were taken before the redesign, so the docs showed a two-way Mode switch, an Active Routes list of addresses, Refresh, Clear and Verify buttons, and a Settings window with the modes as tabs, none of which the app has now. The Domains screenshot was drawn as an inactive window, with grey switches and window buttons. All seven are re-rendered from the real views, drawn as the key window in the dark appearance. A test draws them offscreen with made-up state, and [Development](development.md#screenshots) says how to run it again. The alt text that described the old screens now describes the new ones.
- **Most strings that had no Spanish or French entry now have one.** 5.0.0 showed 96 strings in English on a Mac set to Spanish or French, because neither file had them. Among them were the notifications that say the helper is not running and to repair it from Settings > Status, the dropdown's "Fix…" button and the warning beside it, the Remove All Routes question, the reasons an apply failed, and most of the Routes and Rules pages in Custom mode. The route and rule editors' field labels and the route name hint went through a plain string, so nothing ever looked them up. They are keys now, and so are the editors' error lines ("Name is required.", "Select a route.") and the helper install errors Settings > Status shows. [`scripts/check-localizations.py`](https://github.com/GeiserX/VPN-Bypass/blob/main/scripts/check-localizations.py) collects every localizable string the Swift compiler finds in `Sources/`. It fails when Spanish or French lacks one, or when a translation's placeholders differ from the English ones, and CI runs it on every pull request.
- **Background checks keep running while a question or a menu is open.** The 30-second status check, the DNS refresh and the 12-hour watchdog ran on timers that macOS holds back while an alert waits for an answer or a menu is open. With the mode switch question left on screen, the app stopped checking the VPN and putting back dropped routes until you clicked a button, and a DNS refresh that came due in that time waited too. The three timers now keep firing while an alert or a menu is open. A mode switch made while one of those checks is still changing routes now waits for it to finish and then puts in the routes for the new mode. Before, it saved the new mode and changed no routes.
- **In VPN Only, every count of routed addresses now matches the routes card.** With two entries on the VPN Only list, the card listed 2 addresses and an "Everything else: direct" line, but the header's Addresses fact, the line under Refresh Routes, the Status page and the Addresses Routed notification said 6, because they also counted the 4 catch-all routes the app installs to send everything else direct. Every count now follows the card's rule: the destinations your lists route are counted, and the catch-alls appear only as the "Everything else" line. Bypass and Custom count as before. With only the catch-alls installed, the dropdown still reads ON and the Status page Working, and if the VPN drops and removing them fails, the header says "Everything else still goes direct: removing that failed." With only the catch-alls in place, the wait after a reconnect says "Everything else still goes direct, as before the drop.", Remove All Routes… asks "Stop sending everything else direct?" instead of "Stop routing all 0 addresses?", and a `vpnb routes clear` that could not remove them no longer says it removed all routed addresses: its line says everything else still goes direct. The new sentences are in English, Spanish and French. The `vpnb status` count and the log lines still count every kernel route.
- **Settings > Status shows when a route check is running.** A check clears the last results when it starts, so while one ran the Last check row read "Not checked yet" and the page drew no spinner. Verify greyed out only for a check started by its own button, because the page kept a flag of its own. During a check started after an apply or from the dropdown, Verify stayed clickable. The page now reads the flag every check sets, which the dropdown's Verify icon already uses. While any check runs, the row reads "Checking now…" with a spinner beside a greyed-out Verify. The new text is in English, Spanish and French.
- **Turning a proxy route off now closes its local port.** Its listener on `127.0.0.1` stayed open after the route was turned off, removed, or taken down by a switch out of Custom mode. Turning the route back on then found its own port taken and started it on a random one, so apps set to the old port no longer reached the route. The port is now released when the route stops, and the route comes back on the same port.
- **A ⌘Z still waiting for routes is cancelled by a page switch or a newer change.** ⌘Z pressed while routes are being applied waits up to 10 seconds for them to finish before it puts the change back. Switching page or mode, closing Settings, or a new delete or Turn All On/Off during that wait did not stop it, so a deleted entry came back, or switches flipped back, on a page you had left or after a newer change had replaced the line. Each of those now cancels the waiting undo, as it already dropped the line, and the undo changes nothing.
- **The dropdown and Settings now agree on whether switching to Custom turns your lists into rules.** The dropdown's question went by the config's age. It promised rules whenever the config predated Custom mode (`schemaVersion` 1). The Settings sheet looked at whether any list held something. The switch builds rules only when Custom has none yet and the current mode's list has an entry switched on. So the dropdown disagreed with the switch both ways. A Bypass list with domains and no rules got rules built, and the dropdown did not mention it. A fresh install with nothing listed, or a list whose rules already existed, was promised rules it never got. Both surfaces also promised rules when the only entries were switched off or sat on the other mode's list, such as VPN Only with an empty VPN Only list and domains on the Bypass list. Both now ask whether the switch would build at least one rule. The wording is unchanged and was already in English, Spanish and French.
- **A custom service can no longer share a name with another service or a Bypass list entry.** The app tracks routes by name: a service's name, or the domain itself for a Bypass list entry. A custom service called Netflix, or one called example.com with example.com on the Bypass list, shared that name with the other entry. The dropdown grouped both sets of routes under one row, and removing one could remove the other's routes. The custom service editor now refuses a name that another service or a Bypass list entry already has, ignoring case and spaces around it. It outlines the field in red, says which service or domain has the name and why that matters ("Choose another name, so their routes stay apart."), and keeps Save off. Importing a configuration file with such a name imports nothing and says which service to rename. Undo no longer brings back a deleted service whose name was taken since. The Bypass list, from the Domains tab, Undo or `vpnb domain.add`, refuses a domain a service has as its name. A config.json that already holds such a name loads as before, and renaming or deleting the custom service there puts back the routes of the entry that shared its name. The new text is in English, Spanish and French.
- **Opening the dropdown checks the VPN every time, not only the first time.** The dropdown is meant to re-check the VPN and restore dropped routes each time it opens. It ran that check from SwiftUI's `.onAppear`, but the menu bar keeps one dropdown window for the app's whole life, so `.onAppear` fired on the first open after launch and never again. After that, the dropdown showed whatever the 30-second background check had last found. The check now runs each time the dropdown window takes focus, which happens on every open.
- **`10.0.0.0/24` on the Bypass list is refused instead of saved as the host `10.0.0.0`.** The cleaner cut everything after a `/` as if it were a URL path, so the list showed an entry you never typed and 255 of the 256 addresses you meant still went through the VPN. The Domains tab and `vpnb domain.add` now refuse an IP range there, including an IPv6 range such as `2001:db8::/32`, and point to a rule on the Direct route in Custom mode. In the other direction, `vpnb domain.add` now takes a pasted link on the Bypass list and saves its host, as the Domains tab always has.
- **The Routes tab prints a proxy route's local port without a thousands separator.** The port went through the locale's number formatting, so on a Mac set to Spanish or German the address read `127.0.0.1:18.168`, or `18,168` in English. It now reads `127.0.0.1:18168`. The single Copy button copied shell `export` lines without saying so; it is now two buttons, Copy Proxy URL and Copy Shell Exports. Both carry the listener's password. A bare `127.0.0.1:<port>` gets a 407, so a browser set to `127.0.0.1` and the port asks you to sign in: the user is `vpnb`, and the password is the part between `vpnb:` and `@` in the copied proxy URL.
- **A rule that points at a proxy or Tailscale-peer route says which apps it reaches.** Such a rule adds no kernel route, so it only affects apps set to use that route's local address, while a Direct or VPN rule affects every app. It still claims its hosts first, so a Direct or VPN rule below it for the same hosts adds no kernel route either. The Rules tab drew both kinds the same way, with the difference in a hover-only tooltip. A line under the rule now says "Only apps set to use office-proxy (127.0.0.1:18168) go this way. Other apps take the Mac's normal route to these hosts, even if a rule below also matches them." When the route is switched off, the line says the rule does nothing. The line and the new buttons are translated into Spanish and French.
- **An edit made while the VPN is up no longer costs a full re-apply on the next reconnect.** Since 4.8.5 a reconnect writes nothing unless the configuration changed, and every save counted as a change, including a domain or service edit the app had already applied to the kernel. One edit from the settings window, `vpnb` or an MCP client therefore brought the burst of route writes back on the next reconnect. Only a save made while the VPN is down now triggers the full apply, because only that edit has not reached the kernel.
- **`vpnb mode` with the mode already in use no longer re-applies every route.** The menu picker ignores a click on the active mode, but the socket verb saved the config and re-applied the whole table. It now answers and changes nothing.
- **A VPN reconnect no longer re-installs routes that never left.** In Bypass mode the routes send traffic through the local gateway, so a VPN drop leaves every one of them correct and the app already keeps them. The reconnect still ran a full apply, re-resolving every domain, and because CDN answers rotate the result never matched what was installed, so each reconnect wrote a burst of adds and deletes. On a fragile tunnel that burst was the thing knocking it back down: on one machine, every reconnect apply was followed within 20 seconds by GlobalProtect losing its gateway route, and the backed-off delay from 4.8.2 only spaced the drops out. A warm reconnect now writes nothing as long as the routes are younger than the DNS refresh interval and the configuration has not changed since; the hourly refresh keeps them current, and anything the kernel actually dropped is still restored. VPN Only and Custom keep the reconnect apply, because their routes point at the tunnel.
- **The hourly DNS refresh waits for a calm tunnel.** It used to run on the hour regardless of what the VPN was doing, so it could fire its route writes into a reconnect that was seconds old. It now waits until the VPN has been connected for 10 minutes and no apply-kill strike is outstanding, then retries in 10-minute steps. Refresh from the menu still runs at once.
- **After three apply-kill strikes the post-reconnect apply is withheld, not just delayed.** The exponential backoff capped at 240 seconds, and once a tunnel was that fragile the capped apply still killed it. From the third strike on, the apply waits until the strikes have decayed, which means the tunnel has held for 30 minutes without one.
- **The app no longer spawns `route -n get` to read the default route or the local gateway's interface.** It asks the kernel the same question directly over a routing socket, which is the same lookup the command performs, so the answer is identical, with no child process. On a Mac where endpoint agents inspect every process launch, the old command took a few hundred milliseconds per call and the status pass ran it up to three times every 30 seconds.
- **The loopback proxy's same-user check only counts loopback sockets connected to the proxy.** It used to match any local TCP port, so a connection that reused a port already open on Wi-Fi or Ethernet could be treated as coming from you. The check now requires the socket's local address to be loopback (`127.0.0.1`, `::1`, or IPv4-mapped loopback) and its far side to be the proxy's own port.
- **The privileged helper no longer rewrites a WireGuard or OpenVPN `/1` catch-all.** VPN Only already uses a `/2` quartet so it does not collide with `wg-quick` / OpenVPN `redirect-gateway def1`. A custom rule, import, or `vpnb rule.add match=cidr` of `0.0.0.0/1` or `128.0.0.0/1` still reached the helper and could change those routes, then delete them on teardown. Add and change of any `/0` or `/1` destination are now refused. Delete of the same destinations still works so leftover older `/1`s can be cleaned up. The CLI and the CIDR rule builder reject those prefixes before they are saved or compiled.
- **Routes are restored when macOS drops them after a network change.** With two connections to the same network — Wi-Fi and Ethernet, say — macOS can switch which one traffic actually uses, and it takes that interface's routes with it. Nothing the app watched changed: the connection stayed up, the gateway stayed the same, and both interfaces were still there, so it never noticed its routes were gone and left them missing. With a VPN or Tailscale exit node running, that traffic then went through the tunnel instead of around it. The app now checks the real routing table rather than its own record of what it installed, and puts back anything that vanished.
- **A stuck DNS-cache flush can no longer hang the privileged helper.** After writing `/etc/hosts`, the helper waited forever for `dscacheutil -flushcache` and `killall -HUP mDNSResponder`. If either child wedged, that helper thread stayed blocked for the life of the daemon even after the app gave up at 30 seconds. Those two processes now have a 3-second deadline, then SIGTERM and SIGKILL if they do not exit.
- **With two VPNs running, the app could pick the wrong one.** Several tunnels being up at once is ordinary — a corporate VPN alongside Tailscale — but the app took the first one it happened to see, which had nothing to do with which tunnel was carrying traffic. Because Tailscale usually appears earlier in that list, it could win, and in VPN Only mode the app would then install its rules to escape the wrong tunnel and send the other one's traffic straight out. It now prefers the tunnel actually carrying the default route, never picks Tailscale, keeps its choice stable while several remain valid, and breaks any remaining tie the same way every time.
- **No test that dials a listener sits on a port that can collide or be taken.** Two tests were still exposed after the proxy test fix. The live egress test started its forwarder on port 0, which puts the listener in the range client sockets draw their source ports from, and a client that later lands on an old pair fails to connect with EADDRINUSE. The control socket test that re-points a route expected the fixed port 18099, and three others expected 18077, 18443 and 18944. Each failed whenever something on the Mac held its port, because the listener then fell back to a random one. Every test that opens a listener a client dials now takes its port from one shared helper, `TestPorts.nextListenPort()`, which hands out each port in 20000-48999 once per run and only after binding it first. New tests check that it refuses a port a listener holds and a port a closed connection left in TIME_WAIT.
- **Tests now draw the three places that name a VPN the app does not recognise.** Settings > Status's tunnel list and its Act on menu, and the route editor's VPN menu, are drawn offscreen in English, Spanish and French with one such tunnel, and the tests read what each shows: "VPN", never "Unknown VPN". Before, only the function that picks the label had a test, so a view that stopped calling it would still have passed.
- **VoiceOver names every menu and segmented control in the route and rule editors and the DNS refresh interval.** Six of them had an empty name, so VoiceOver read them as just "pop-up button" or "radio group": the route editor's Type, Tailscale Peer and VPN controls, the rule editor's Match and Service controls, and General's Refresh Interval menu. Each now reads as its visible caption, in English, Spanish and French, and the route editor's VPN menu lines up under its caption. The Tailscale Peer menu's "exit node" suffix is now in Spanish and French too.

### Changed
- **"Route" means one thing on screen, and the Bypass list is no longer called Custom Domains.** "Route" named three things: the kernel entries the app installs ("62 routes" in the dropdown and on the Status page), the ways out in Custom mode (the Routes page, "1/1 active"), and the ways out that have rules (Routes In Use). A user reading "62 routes" next to "1/1 active" was counting two different things under one word. "Route" now means only a way out in Custom mode: Direct, a VPN, a proxy or a Tailscale peer. Every count of kernel entries reads as addresses: "Telegram, 12 addresses", "62 addresses routed 23 s ago, none failed", "Checked 10 of 62 addresses", the Addresses fact and the Addresses section on the Status page, the NOTHING ROUTED pill, the notifications and the "Last change" line after a `routes.clear`. One address now reads in the singular ("1 address stays routed for when it reconnects."), where "1 route" used to land in a plural sentence. The Domains page is titled Bypass list or VPN Only list, after its mode, instead of Custom Domains or VPN Only Domains. The command names Refresh Routes, Verify Routes and Remove All Routes… keep their names, and so do the socket verbs (`routes.active`, `routes.clear`) and the log lines. The new text is in English, Spanish and French.
- **Verify Routes says what it checked, and lists failures first.** Verify pings at most 10 addresses: single addresses only, because ping cannot test a range, and the first 10 in sort order. Its card showed a count such as "10/10" under a header that said 62 routes, so a sample read as every route checked. It listed three results in no fixed order, so a failure could sit in the seven it did not show. The card, now called Route check, says "Checked 10 of 62 routes (single addresses only).", lists the addresses that did not answer first, up to three with what each is routed for and why it failed and then "+ N more", and sums up the rest in one line with their response times ("9 reachable, 24 to 118 ms"). With only ranges routed it says there was nothing ping could check, where it used to show nothing. Verify now logs one line per address, and the card's "Show all 10 results in Logs" opens Settings on the Logs page. The new text is in English, Spanish and French.
- **The dropdown lists what is routed by what you added, not by address.** It showed your services as chips, then Active Routes as raw addresses, the first four that happened to sort first and then "+ 58 more". Telegram showed up twice, once as a chip and again as two address ranges. In VPN Only mode four of the six rows were the app's own catch-all routes, and the count included them. The two cards are now one list, Skipping the VPN in Bypass and Through the VPN in VPN Only, with one row per service, domain or IP range you have on, in the order Settings lists them, and its route count ("Telegram, 12 routes"). The header gives the total. Hover over a row to see its addresses. An entry that has no routes while nothing is applying or waiting to apply gets an amber mark and "no routes". In VPN Only the catch-all routes are one line, "Everything else: direct", and the count leaves them out. Routes that no entry owns, such as those of an entry you just removed while they wait to be cleaned up, are one "Left from earlier" line. Custom mode lists its rules that installed a route, under Routed by your rules. The new text is in English, Spanish and French. How routes are applied has not changed.
- **Deletes and Turn All On/Off in Settings can be undone.** Every trash button removed its domain, custom service, rule or route on the first click with no way back, and a custom service took its whole domain list with it. All turned on every service at once, so 33 services could leave the VPN in one click, and None was red like a delete though it only switched things off. A delete now leaves a line in the list ("Removed Work Tools and its 5 domains.") with an Undo button, and Edit > Undo (⌘Z) does the same. Undo puts the entry back in its place with its switch as it was, through the same code as adding it, so its routes come back too. All and None are now Turn All On and Turn All Off in a ⋯ menu, on the Domains and Services pages, and they leave the same line. Turn All On for services asks first when it would turn on more than five ("Send 33 services around the VPN?"), with Cancel as the default button. The new text is in English, Spanish and French.
- **The Services page lists the services that are on first.** The 37 built-in services sat in one fixed order, so the ones you had on were spread through the list, often below the fold. They now sit in an On section at the top, custom ones included. The rest follow in the usual order under Custom Services and Built-in Services, and each header gives its count. A switch you flip on the page keeps its row where it is until you next open the page. All and None re-sort the list at once. Search filters every section. The headers are in English, Spanish and French.
- **In Settings, the routing mode no longer looks like a page button.** The three modes sat above the page buttons in the same green pills, so a click meant to open the VPN Only list asked to switch the whole Mac. The page buttons are now a toolbar under the title bar, with the icon above the label and a plain highlight on the page shown. The mode is a menu at the right end of the title bar that reads "Mode Bypass" and checks the mode in use; on macOS 14.4 and later each mode has a short line under its name. Picking another mode opens a sheet that lists the three modes, with one sentence each and what your lists hold for it ("4 services and 2 domains", "3 entries", or "Your lists become rules" before the first switch to Custom). Nothing changes until Switch, which goes through the same mode switch as before. The sheet and the menu are in English, Spanish and French.
- **The top of the dropdown says what the app is doing, including while it waits after a reconnect.** It used to show a green ON pill, "VPN Connected" and a route-count badge, and all three stayed green while the app deliberately waited before re-applying routes after a reconnect, or withheld the apply for up to 30 minutes after repeated apply-kill strikes. That waiting was only in the log. The header now names the VPN, says in one sentence what your lists route ("4 services and 2 domains skip the VPN."), and lists when routes were last applied and whether any failed, and when DNS was checked and runs next. After a reconnect the pill reads WAITING and the header counts down to the apply. When the apply is withheld the pill reads HELD BACK, and the header says how many times the tunnel dropped right after an apply, how long the app will wait, and that Refresh Routes applies right away. The route-count badge is gone; the count is in the facts.
- **The dropdown's Mode control offers all three modes, in every mode.** It was two hand-drawn buttons, Bypass and VPN Only. In Custom mode they gave way to a "Custom Routes" capsule and a "Switch to Bypass" link, so the dropdown could not pick Custom, and from Custom it could not reach VPN Only. It is now a native segmented control with Bypass, VPN Only and Custom. Picking another mode still asks first. The selection moves only after you confirm, and Cancel leaves it where it was. Entering Custom from the dropdown turns your lists into rules, as Settings does. The question now shows the app's logo. It used to open as a sheet on the dropdown, and macOS 26 draws no icon on an alert sheet. Its title, message and buttons now have Spanish and French translations. The facts under the header no longer list the mode, because the control sits right below them. Hover over the control to see what the current mode does.
- **Clear now sits behind a menu and asks first, and Refresh Routes says what it did.** Clear was the same size as Refresh Routes, right next to it, and one click removed every route with no question and no message after. It is now Remove All Routes… in the "…" menu next to Refresh Routes, with Verify Routes and Re-resolve DNS Now, and it asks first. The question says what it costs in your terms, for example "Your 4 services and 2 domains will go through the VPN until you refresh routes, the VPN reconnects, or DNS is next refreshed", and Cancel is the default. Verify Routes is also a small icon next to Refresh Routes. Under the buttons, one line gives the result of the last apply, such as "62 routes applied 23 s ago, none failed", or says that all routes were removed. It replaces the footer's "Updated … ago", which did not say what was updated and read fresh right after Clear. While a refresh runs, the dropdown keeps its content and the button reads "Refreshing routes…" instead of the whole dropdown switching to "Setting Up…".
- Updating the helper to 2.2.1 asks for one admin prompt so already-installed helpers pick up the `/1` install refusal.
- Updating the helper to 2.1.1 asks for one admin prompt so already-installed helpers pick up the flush deadline.

## [3.1.13] - 2026-08-07

### Fixed
- **A VPN reconnect no longer triggers a full route rebuild seconds later.** The app reads the VPN's gateway either as an address or, when it can't read one, as the interface name — two ways of writing the same thing. It was comparing them as text, so an unchanged tunnel looked like it had switched gateways, and the app responded by re-installing every route. Seen live: a "gateway changed" a few seconds after GlobalProtect reconnected, followed by 317 routes being written at once, which was enough to knock the freshly-established tunnel down again. Only a genuine change of address now counts.

## [3.1.12] - 2026-08-07

### Fixed
- **VPN Bypass can no longer mistake Tailscale for your VPN.** To tell apart the different services that share the `100.64.x` address range (Tailscale, Zscaler, Cloudflare WARP), the app asks Tailscale directly. If that question couldn't be answered — the command missing, or timing out under load — the app treated the address as your corporate VPN and would start re-routing traffic around your Tailscale mesh. It now declines whenever it can't be sure, because claiming another tool's tunnel is never the safe assumption.
- **The app will no longer touch routes belonging to other network software.** Nothing previously stopped it writing a route for Tailscale's own address range or its DNS server. Listing Tailscale's range in VPN Only mode would have silently redirected the whole tailnet into the corporate tunnel, and removing it later would have deleted Tailscale's route outright — breaking mesh networking with nothing to indicate this app was responsible. Those destinations, along with loopback, link-local, multicast and broadcast, are now refused outright by the privileged helper, so the refusal holds no matter what the app asks for.

## [3.1.11] - 2026-08-07

### Fixed
- **Bypass routes could be sent through the VPN instead of around it.** The app worked out your normal gateway by trying a fixed list of network names — "Wi-Fi", "Ethernet" and a few USB adapters. If your Mac's active connection is named anything else, which is the norm for docks ("USB3.0 5K Graphic Docking", "Dell Universal Dock D6000"), none of them matched and the app fell back to reading the current default route. Once a VPN is connected that route belongs to the VPN, so the app used the **VPN's own gateway** as your "normal" connection: every bypass route was then pointed straight back into the tunnel it was meant to avoid, and bypassing silently did nothing. Worse, the gateway changed every time the VPN connected or dropped, so the entire route set was rebuilt on every flap — on one machine, 362 routes and 286 removals in a single minute. The app now asks macOS for the real list of network services in its own priority order, and refuses to treat a VPN tunnel as your normal gateway.
- **The app no longer forgets routes it failed to remove.** If the privileged helper wasn't available when routes were being cleaned up, the app logged that it couldn't remove them — and then cleared its own record of them anyway. Since that record is the only thing identifying those routes as ours, they were left in place with nothing able to find or remove them afterwards. This was reachable on an ordinary quit, and in VPN Only mode the leftovers could include the catch-all routes, which send every connection around the VPN. The record is now kept whenever removal didn't actually succeed.

## [3.1.10] - 2026-08-07

### Fixed
- **A VPN reconnect no longer rebuilds every route.** When the VPN dropped, the app removed *all* of its routes and re-added them once it came back. With a tunnel that reconnects often this dominated everything — one machine logged 15 disconnects and 8 full 342-route rebuilds in a single day, and each rebuild fires hundreds of routing-table changes that the VPN client itself then reacts to, feeding the very instability that caused the disconnect. In Bypass mode your routes go through your normal connection, so they stay perfectly valid while the VPN is away; they are now kept, and a reconnect finds them already correct and changes nothing. VPN Only still tears down fully, because its routes genuinely do point at a gateway that has gone.
- **A VPN that reconnects on a new gateway is now noticed.** If the tunnel came back on the same interface but a different next-hop, nothing detected it and the routes stayed pinned to a gateway that no longer existed — those destinations silently stopped working until the next restart.
- **Quitting no longer abandons routes half-removed.** The shutdown cleanup was given a flat 8 seconds regardless of how many routes existed; with a few hundred it was cut off partway through, and whatever remained could never be cleaned up afterwards. The time allowed now scales with the number of routes.

### Changed
- The menu bar now says which mode is active and what it means, instead of only a route count. Bypass and VPN Only are near-opposites and used to look identical.

## [3.1.9] - 2026-08-07

### Fixed
- **A route could be silently skipped and never installed.** The "is this route already correct?" check added in 3.1.8 didn't look at route flags, so a short-lived route the kernel creates automatically (which inherits its gateway from the default route) could be mistaken for one of ours. The app then recorded the route as applied, wrote nothing, and the temporary route later expired — leaving that destination going somewhere else entirely, with no error anywhere. The check is now much stricter about what counts as a match.
- **VPN Only still rewrote its catch-all routes on every pass.** The 3.1.8 fix skipped network routes, which is exactly what VPN Only's two catch-alls are — so the churn that destabilises other VPN clients was never fixed in the mode where it matters most.
- **VPN Only briefly sent protected traffic in the clear on every apply.** The catch-all routes were installed *before* the routes for your listed domains, so for the duration of an apply — hundreds of routes, one at a time — the very destinations you asked to protect fell back to your normal connection. Catch-alls are now installed last, mirroring teardown, which already removes them first.
- **VPN Only left all traffic outside the tunnel when GlobalProtect appeared.** The app refuses to enable VPN Only under GlobalProtect, but it only refused to *add* the catch-alls — any already installed stayed, silently routing everything around the tunnel while the app looked healthy. They are now removed, and you're told why.
- **Upgrading left every route behind.** Quitting the app cleans up its routes, but the Homebrew upgrade path stops the app with a signal that skipped that cleanup entirely — so an upgrade stranded the whole route set with nothing able to remove it afterwards. Routes are now cleaned up on that path too.
- **A stuck `route` command could freeze all routing changes.** Since 3.1.7 route operations run one at a time, so a single hung command blocked every later change for as long as the helper stayed running. Commands are now bounded and cancelled if they overrun.
- **Failing to route anything at all is no longer silent.** The one case guaranteed to produce no notification was total failure. You now get told when no routes could be applied — no gateway, no VPN for VPN Only, or the helper not being ready.
- **Corrected the mode descriptions in the README and roadmap**, which had VPN Only backwards — they described it as sending everything *through* the VPN except your list, when it does the opposite.

### Changed
- Helper version 1.10.0 → 1.11.0 (one admin prompt on first launch after upgrading).
- The privileged helper now rejects a `/0` route, matching the app.
- Tests no longer read or write the real DNS cache file.

## [3.1.8] - 2026-08-06

### Fixed
- **Re-applying a route that is already correct no longer touches the routing table.** 3.1.7 stopped the re-route teardown and replaced delete-before-add with a change-in-place, but it did not stop the churn: the app legitimately re-applies its whole route set on a schedule (DNS refresh, the 15-second failed-domain retry, periodic status passes), and the helper wrote *every* route on *every* pass — even when the kernel already held exactly that route. Measured on a live machine running 3.1.7: 48+ `route` processes in 150 seconds, in bursts of ~180 routing-table writes. Every write is an event that other VPN clients react to, which is what destabilised GlobalProtect. The helper now checks the existing route first and skips the write entirely when nothing would change, so a steady state with no network change costs zero routing-table writes.
- **Every privileged route operation is now logged.** 1.9.0 logged only batch operations and failures, so per-route work was invisible in the system log — which is how the remaining churn went unnoticed after 3.1.7. Inspect with `log stream --predicate 'subsystem == "com.geiserx.vpnbypass.helper"' --info`.

### Changed
- Helper version 1.9.0 → 1.10.0, so an installed helper picks up the fix (one admin prompt on first launch after upgrading).

## [3.1.7] - 2026-08-04

### Fixed
- **VPN Bypass no longer destabilises other VPN clients (GlobalProtect disconnect loop).** Two habits made the app rewrite the routing table constantly even when nothing had changed, and every routing-table write is an event that enterprise VPN clients react to — one measured machine logged 757 route-change events and 48 tunnel teardowns over roughly 6.5 hours of active use — about one disconnect every 8 minutes, with ~27 seconds of downtime each.
  - **Re-routing rebuilt everything instead of reconciling.** When the VPN interface changed, the app removed every route it managed and re-installed the whole set. Because the teardown also cleared its own record of what was installed, the "nothing changed, skip this" check could never fire on that path. In Bypass mode the routes point at your local gateway, so a VPN reconnect changed nothing about them — the entire rebuild produced exactly the routes that were already there. Re-routing now reconciles: it applies only what genuinely differs, and does nothing at all when the routes are already correct.
  - **Every route was deleted before it was added.** The privileged helper issued a blind `route delete` ahead of each `route add`, which doubled the number of routing-table writes and briefly left the destination with no route at all — the exact condition that makes another VPN client's gateway check fail. It now changes the route in place, adds only when nothing was there, and falls back to a replace only in the rare case where both are refused.
- **Route operations can no longer overlap.** Helper-side route and hosts-file changes are serialised across connections, so two requests can't mutate the routing table simultaneously.
- **A stuck route-operation lock can no longer wedge the app.** The re-route path released its lock without a `defer`, so an interruption at the wrong moment left it held permanently — silently disabling every later route apply, re-route and DNS refresh for the life of the process.

### Added
- **The privileged helper now logs.** It previously produced no diagnostics at all. Inspect with `log stream --predicate 'subsystem == "com.geiserx.vpnbypass.helper"' --info`.

### Changed
- Helper version 1.8.0 → 1.9.0, so an installed helper picks up the fixes above (one admin prompt on first launch after upgrading).

## [3.1.5] - 2026-07-18

### Fixed
- **No stranded routes when an apply is interrupted mid-install (VPN-Only leak).** Every route-apply path added routes to the kernel *before* recording them internally, so if a teardown (VPN disconnect, app quit, or a config change) landed in that brief window, the just-added routes could be left installed but untracked — and in VPN Only mode the `0.0.0.0/1` + `128.0.0.0/1` catch-alls could then survive a disconnect and route all traffic to a dead gateway (a silent, persistent leak until the next refresh/reconnect). Each apply now self-remediates on interruption: it removes exactly the routes it just added (catch-alls first) instead of abandoning them, so nothing is ever left installed-but-untracked. Teardown itself is unchanged (still prompt and catch-all-first), and classic Bypass/VPN Only route sets stay byte-identical.

## [3.1.4] - 2026-07-18

Classic **Bypass** and **VPN Only** route application stays byte-identical — both fixes below preserve the normal path, and each ships with new regression tests.

### Security
- **The privileged helper no longer accepts a forgeable identity.** When the root-only cdhash pin was absent (never written, or removed), the helper fell back to authorizing XPC callers by code-signing *identifier* alone — and under ad-hoc signing that identifier is forgeable (`codesign -s - -i …`), so a locally-built binary could drive the root helper. The helper is now **fail-closed**: no valid pin means the caller is rejected. To keep that from ever locking out the real app, the installer now *guarantees* the pin (the modern install verifies it landed, otherwise falls back to the atomic legacy install; the legacy path refuses to install pin-less), and the readiness gate self-heals a missing/stale pin by reinstalling. Helper version 1.7.0 → 1.8.0 so existing installs reinstall once and pick up the fail-closed build. The app also re-verifies the cdhash pin on its readiness fast path (fail-closed if it can't be confirmed), so a pin removed or rotated after launch self-heals via reinstall instead of leaving the app reporting a stale "ready." Verified on real hardware: a forged binary claiming our identifier is rejected, a correctly-pinned install stays ready (no brick), and a missing/mismatched pin fails closed.

### Fixed
- **No silent leak when a reroute is dropped.** On an interface change or Tailscale state change, VPN-Only link-interface routes are re-pinned to the live interface. That reroute was fire-once: if it arrived while the route-operation gate was held or during the post-change cooldown, it was lost, leaving VPN-Only routes pinned to a dead `utun` — a silent leak. The reroute is now latched and retried until it actually applies, so a change that lands at a busy moment is never dropped. It still applies the exact same route set (remove-all then re-apply), so classic Bypass/VPN-Only output is unchanged.

## [3.1.3] - 2026-07-18

### Changed
- **Docs corrected to match shipped reality** — README and CHANGELOG installation/CLI instructions were updated for accuracy: the cask-scoped `brew trust` command now appears before the install step, and the manual-DMG `vpnb` path is quoted as an absolute path so it's copy/paste-safe.
- **Removed unused `NotificationManager` methods** — 5 dead-code methods with no remaining callers were removed; no behavior change.
- **Hardened the release workflow** — the `concurrency` group now keys on the release version instead of `github.ref`, so a tag push and a same-version `workflow_dispatch` run always serialize instead of racing; third-party GitHub Actions used in `release.yml` are pinned to a commit SHA.

## [3.1.2] - 2026-07-07

### Fixed
- **`vpnb` CLI now lands on your `PATH`** — the `vpnb` control CLI has shipped bundled inside the app since 3.0.0, but the cask never linked it, so `vpnb` wasn't runnable from a terminal after a Homebrew install. Installing via the tap (`brew tap geiserx/vpn-bypass && brew install --cask vpn-bypass`) now symlinks the bundled `vpnb` onto `PATH`. Manual DMG installs can still call it at `"/Applications/VPN Bypass.app/Contents/MacOS/vpnb"` or symlink it themselves.

## [3.1.1] - 2026-07-04

Classic **Bypass** and **VPN Only** route application stays byte-identical — every change here is behavior-preserving, and the DNS-refresh path now has its first regression test net.

### Fixed
- **The audit-token helper hardening now actually reaches existing installs** — 3.1.0 taught the privileged helper to verify XPC callers by their kernel audit token, but didn't bump the helper's version, so already-installed helpers never updated and kept the older process-ID check. The helper version is bumped (1.6.0 → 1.7.0) so existing installs detect the mismatch, reinstall once (a one-time admin prompt on first launch), and receive the hardened helper.

### Changed
- **Faster recurring DNS refresh** — the periodic re-resolution of your domains now runs in parallel instead of one domain at a time, so a large domain/service set refreshes quickly without holding up route updates. The refresh's route planning was lifted into a pure, unit-tested unit and proven set-equivalent to the old inline code, so exactly the same routes are installed.
- **Continued routing-core cleanup** — the DNS resolver and process-runner internals were extracted into standalone, tested units, shrinking the routing controller further (part of the ongoing refactor from 3.0.1).

## [3.1.0] - 2026-07-04

### Changed
- **Hardened privileged-helper authentication** — the root helper now verifies each XPC caller by its kernel **audit token** instead of the reusable process ID, closing a PID-reuse race where a short-lived forged process could momentarily impersonate the app. The helper stays ad-hoc-signable with no Network Extension entitlements and keeps its anti-brick fallback. (Reaching already-installed helpers is completed in 3.1.1.)
- **Config model extracted** — the configuration, routing-mode, proxy, domain, and service types were lifted out of the routing controller into a standalone model file (behavior-preserving; identical on-disk config format), continuing the routing-core refactor.

## [3.0.1] - 2026-07-04

A hardening release from a whole-codebase review. Classic **Bypass** and **VPN Only** route application stays byte-identical to 3.0.0 (same kernel routes, same `/etc/hosts` output) — every routing change here is behavior-preserving, proven by a new test net.

### Fixed
- **No orphaned routes on a helper timeout** — if a route-install batch timed out (a slow, not dead, helper), the app used to record none of the routes it may have installed, so they could survive VPN disconnect and quit — traffic stuck at a dead gateway. The app now records those routes so teardown removes them.
- **Hosts-file failures are surfaced** — a failed `/etc/hosts` update is now reported as a warning instead of being logged as success while the file silently drifted from the kernel routes.
- **Catch-all routes torn down first** — on quit/teardown the VPN-Only `0.0.0.0/1`+`128.0.0.0/1` catch-alls are removed before per-host routes, so a time-capped quit can't strand a full-tunnel-defeating route.
- **Healthy helper no longer needlessly reinstalled** — a helper that's merely slow to answer at launch is retried once before the app concludes it's broken and prompts for an admin reinstall.
- **More complete logging** — helper install/update and notification failures now reach the log (and the Logs tab) instead of vanishing to stdout; DNS-cache read/write failures are surfaced rather than swallowed.

### Changed
- **Routing core refactor (behavior-preserving)** — classic route-building was lifted into a pure, exhaustively-tested compiler and the duplicated apply logic was unified, so the default-mode path finally has a regression test net.
- **Hardened debug log** — moved to `~/Library/Logs/VPNBypass/`, created owner-only (off the world-readable `/tmp`), and made cheaper to write on the hot path.
- **Bounded DNS resolution** — domain resolution is capped with a sliding window so a large domain set can't spawn a subprocess fork-storm.
- Dead code removed; whole package builds with zero warnings.

## [3.0.0] - 2026-07-03

### Added
- **Custom routing mode** — A third routing mode alongside Bypass and VPN Only. Custom mode runs a per-rule dispatch engine: each rule maps a domain, service, or CIDR to a named route (egress), evaluated in order (first match wins) with a pinned "everything else → default" rule. This is a major addition; **Bypass and VPN Only remain the defaults and are unchanged** — existing users see no difference until they opt into Custom.
- **Multiple egress types** — Custom-mode routes can send traffic out through several egresses: the local gateway (direct), a specific VPN interface (multi-VPN — pick *which* tunnel per rule), an HTTP or SOCKS5 **proxy** via a local `127.0.0.1` listener, or a **Tailscale peer** used as an exit (proxy-over-tailnet, so per-destination routing works without changing any Tailscale settings).
- **`vpnb` command-line interface** — A bundled CLI (a second executable inside the app bundle) that scripts the app over a user-only UNIX socket using dot-verb `key=value` arguments: `status`, `route.add`/`route.set`/`route.rm`, `rule.add`/`rule.rm`, `mode`, and `default`. Secrets are read from stdin/env (never argv), and it honors `VPNB_SOCKET`. It drives the same routing paths a GUI action does — no new privilege.
- **Rules and Routes tabs** — Custom mode adds a Rules tab (ordered, first-match rule list) and a Routes tab (auto-detected system routes — each VPN link plus Direct — alongside your own proxy and Tailscale-peer routes). The Settings window now has up to seven tabs (Domains, Services, Rules, Routes, General, Logs, Info); the visible set depends on the active mode.

### Changed
- **Privileged helper 1.6.0** — The helper is now cdhash-pinned and stays ad-hoc-signable, with no Network Extension entitlements. Existing users are prompted once to update the helper on first launch.
- **Routing engine generalized to routes + rules** — Bypass and VPN Only are preserved as the default apply path; Custom mode compiles its rules into the same route batches the existing engine already applies, so the hard-won teardown and re-assertion guards are shared rather than reimplemented.

## [2.9.1] - 2026-06-09

### Fixed
- **Homebrew cask deprecation** — Replaced the deprecated `depends_on macos: ">= :ventura"` string-comparison form with the modern `depends_on macos: :ventura` symbol form, silencing the `brew` deprecation warning. Semantics are unchanged (macOS Ventura 13 or newer). Thanks to @gcpmusic for the report (#49).

## [2.9.0] - 2026-06-09

### Changed
- **New app icon & logo** — Refreshed the app icon, in-app logo, and README banner with @Tetonne's community-suggested shield design (dark-navy macOS squircle). See #39.

### Fixed
- **"Setting Up…" hang** — When the privileged helper is not yet ready, the menu now shows real VPN/network status instead of spinning on "Setting Up…" indefinitely.

## [2.8.1] - 2026-05-04

### Fixed
- **Custom service editor** — Changed placeholder from "My Company VPN" to "My Service". Added domain format validation — domains must contain at least one dot (e.g. `example.com`), preventing invalid entries like `aa`.

## [2.8.0] - 2026-05-04

### Improved
- **Services tab UI** — Added "+" button in the header for quick custom service creation. Services list is now split into "Custom Services" (top) and "Built-in Services" sections with clear headers. Custom badge contrast improved for readability. Edit/delete buttons for custom services are always visible (no longer hover-only). Removed the old full-width bottom button that was hidden by scroll.

## [2.7.2] - 2026-05-04

### Fixed
- **XPC batch timeout** — Increased per-route timeout budget from 0.1s to 0.25s. The helper does delete-before-add (2 subprocess calls at ~0.14s/route), so the old budget caused timeouts for batches above ~250 routes, silently dropping all routes.

## [2.7.1] - 2026-05-04

### Fixed
- **Test isolation** — Integration tests no longer overwrite the production config.json. Added file-level snapshot/restore around each test class to prevent config corruption during `swift test` runs.

## [2.7.0] - 2026-05-04

### Changed
- **Library extraction** — Extracted `VPNBypassCore` as a separate SPM library target, enabling unit testing of business logic without launching the full app

### Added
- **552 unit tests** across 10 new test files covering RouteManager config mutations, domain cleaning, IP/CIDR validation, Codable roundtrips, HelperState, notification preferences, Theme constants, and more
- **Codecov integration** — Coverage tracking with exclusions for system-dependent code (XPC, VPN detection, SwiftUI views)

## [2.6.2] - 2026-05-03

### Fixed
- **Spurious VPN notifications** — Suppress transient VPN interface flaps that caused repeated "VPN Connected" notifications while VPN was still active. Now rechecks after 1.5s before committing to a disconnect state.

## [2.6.1] - 2026-05-03

### Removed
- **Wildcard domain support** — Removed `*.example.com` syntax. macOS routing is IP-based and `/etc/hosts` does not support wildcards, so the feature only resolved the base domain and could not actually route subdomains with different IPs. This was misleading.

### Changed
- **Simplified `DomainEntry`** — Removed `resolvableDomain` computed property (no longer needed without wildcards)

## [2.6.0] - 2026-05-03

### Added
- **Centralized theme system** — New `Theme.swift` with semantic colors, WCAG AA-compliant contrast ratios, and consolidated brand identity (`Theme.Brand`)
- **Menu bar state icons** — Three distinct template images (default/active/error) for at-a-glance status
- **Modern app icon** — Redesigned shield icon with gradient and arrow motif
- **VoiceOver accessibility** — Menu bar icon announces current state (active routes count, helper errors, etc.)
- **Reduced motion support** — Pulse animation respects `accessibilityReduceMotion` system preference

### Fixed
- **Retry DNS tracking** — `retryFailedDomain` now passes the `source:` parameter for correct route tracking
- **Reactive helper state** — Menu bar icon updates immediately when helper state changes (was reading a static reference)
- **DNS input validation** — `resolveWithDNSParallel` now rejects whitespace, semicolons, and shell metacharacters in DNS server strings
- **Theme consistency** — Replaced remaining hardcoded `Color.white.opacity()` values with semantic theme tokens
- **WCAG AA compliance** — `textDisabled` color bumped from 3.95:1 to 4.6:1 contrast ratio

### Changed
- **250+ hardcoded colors replaced** with semantic `Theme.*` tokens across all views
- **`BrandColors` consolidated** into `Theme.Brand` nested enum (single source of truth)

## [2.4.2] - 2026-04-10

### Fixed
- **VPN Gateway Race Condition** - VPN Only mode used the local router as VPN gateway when VPN routing table wasn't fully ready at detection time. Now skips gateway IPs that match the local gateway and re-detects gateway when switching to VPN Only mode ([#26](https://github.com/GeiserX/VPN-Bypass/issues/26))

## [2.4.1] - 2026-04-10

### Fixed
- **Multi-VPN Interface Selection** - VPN Only mode now prefers the `interface:` reported by `route -n get default` instead of the first VPN-looking interface from `ifconfig` when no IP gateway is available, fixing wrong-tunnel selection in multi-VPN setups ([#27](https://github.com/GeiserX/VPN-Bypass/pull/27))
- **Safer Route Interface Fallback** - Route-derived interface fallback is now accepted only when it still looks like a VPN/tunnel device, preserving the existing ifconfig fallback for odd default-route outputs

## [2.4.0] - 2026-04-10

### Added
- **Cisco Secure Client Support** - VPN Only mode now works with Cisco Secure Client (AnyConnect) which routes via interface link instead of an IP gateway. The helper supports interface-based routing (`-interface utun`) when no gateway IP is available ([#26](https://github.com/GeiserX/VPN-Bypass/issues/26))
- **Improved Cisco Detection** - Added `secureclient` process name matching for Cisco Secure Client 5.x identification

### Changed
- **Helper v1.4.0** - Updated privileged helper to support interface-based route addition. Existing users will be prompted once to update the helper on first launch

## [2.3.3] - 2026-04-08

### Added
- **Login Item Detection** - Detects when users disable VPN Bypass in System Settings → Login Items and shows a helpful error message instead of re-prompting for admin password on every boot ([#25](https://github.com/GeiserX/VPN-Bypass/issues/25))

## [2.3.2] - 2026-04-08

### Fixed
- **Tab Label Wrapping** - Spanish/French tab labels no longer wrap mid-word; compact sizing applied only for non-English languages while keeping original size for English

## [2.3.1] - 2026-04-08

### Changed
- **Author Subtitle** - Updated author credit in Info tab

## [2.3.0] - 2026-04-08

### Added
- **Localization** - Full English, Spanish, and French translations for all UI strings including settings, menu bar, helper status messages, and error states ([#24](https://github.com/GeiserX/VPN-Bypass/pull/24))

## [2.2.0] - 2026-04-06

### Added
- **Intel Mac Support** - App and helper are now built as universal binaries (arm64 + x86_64), fixing launch failures on Intel Macs ([#22](https://github.com/GeiserX/VPN-Bypass/issues/22))

### Fixed
- **Settings Window Minimize** - Settings window now shows a Dock icon while open, so the minimize button works correctly instead of sending the window to an invisible Dock section

## [2.1.2] - 2026-03-31

### Fixed
- **Menu Bar Icon Redesign** - Replaced complex 13-point arrow (unreadable at 18px) with a clean bold right-arrow (7 points). Re-rendered from SVG with proper alpha transparency
- **Dropdown/Settings Logo Artifacts** - Replaced raw 650x514 PNG (artifact-heavy at small sizes) with `NSApp.applicationIconImage` which macOS renders optimized for each display size

## [2.1.1] - 2026-03-31

### Fixed
- **Menu Bar Black Square** - Converted menu bar icons from 16-bit to 8-bit grayscale+alpha; CoreGraphics `mask_create` rejects 16-bit images as template masks
- **Helper Update Not Taking Effect** - `SMAppService.register()` silently succeeds without replacing the on-disk binary; helper updates now always use the legacy AppleScript path which does the actual file copy and `launchctl` reload

## [2.1.0] - 2026-03-31

### Changed
- **Native Settings Window** - Replaced persistent `NSPanel` with a standard `NSWindow` featuring minimize, close, and full traffic light controls
- **Official Logo Everywhere** - Menu bar uses a template icon (`menubar-icon.png`) for proper dark/light mode, dropdown header uses the official 3D logo instead of SF Symbols
- **Larger Tab Buttons** - Settings tab items enlarged to 13pt with rounded-rectangle styling for better usability
- **Git-Derived Version** - App version is now stamped from the latest git tag at build time via `PlistBuddy`, eliminating hardcoded version strings

### Fixed
- **Helper Startup Race** - App no longer hangs at "Setting Up" when the privileged helper is outdated. A new `ensureHelperReady()` preflight verifies the helper is installed, running, and at the expected version before any route application begins
- **XPC Timeout Protection** - All XPC calls now use a hard wall-clock deadline (`OnceGate` + `DispatchQueue.asyncAfter`) instead of cooperative task cancellation, preventing indefinite hangs when the helper is unresponsive
- **Helper State Machine** - New `HelperState` enum (`missing`, `checking`, `installing`, `outdated`, `ready`, `failed`) with reactive UI throughout the app
- **Auto-Update on Version Mismatch** - Helper is automatically reinstalled when version mismatch is detected, with XPC connection reset and post-update verification
- **Helperless Fallback Removal** - All direct `/sbin/route` and AppleScript fallback paths removed; every route-mutating operation now requires the privileged helper, eliminating silent failures and false state
- **Settings Recovery** - Install/Update/Retry button in Settings runs full `ensureHelperReady()` preflight and automatically applies routes + restarts DNS timer if VPN is connected
- **Window Minimize/Reopen** - Minimized settings window is properly restored instead of creating a new instance
- **Strict Concurrency** - `OnceGate` marked `@unchecked Sendable` with `T: Sendable` constraint, eliminating all strict-concurrency warnings from the XPC deadline infrastructure

## [2.0.0] - 2026-03-30

### Added
- **VPN Only Mode (Inverse Routing)** - New dual routing mode: "Bypass" (default, existing behavior) and "VPN Only" where only listed domains use VPN while everything else bypasses it. Uses 0.0.0.0/1 + 128.0.0.0/1 catch-all routes through the local gateway with domain-specific routes through the VPN gateway
- **Routing Mode Selector** - Radio-button mode selector in both the menu bar dropdown and the Settings Domains tab to switch between Bypass and VPN Only modes
- **Separate Domain Lists** - Each routing mode maintains its own domain list: bypass domains for Bypass mode, VPN-only domains for VPN Only mode
- **Custom Services** - Create your own service entries with a name, multiple domains, and optional IP ranges. Custom services are shown with a purple "Custom" badge, can be edited/deleted, and persist across reboots
- **Custom Service Editor** - Full sheet editor for creating and editing custom services with add/remove buttons for domains and IP ranges
- **Multi-Source Route Ownership** - Routes now track their origin (service name, domain, or CIDR) via `allSourceEntries`, preventing cross-source conflicts during incremental updates

### Changed
- **Services Tab** - Shows a disabled banner in VPN Only mode (services only apply in Bypass mode). Added "+ Create Custom Service" button for user-defined services
- **VPN Gateway Detection** - App now detects both local and VPN gateways simultaneously for inverse routing support
- **Route Operation Serialization** - Complete rewrite of concurrency model: exclusive `acquireRouteOperation`/`releaseRouteOperation` gate prevents concurrent route modifications, epoch-based preemption detection (`routeEpoch`) ensures teardown safely cancels in-flight operations, and gate-free teardown guarantees disconnect/quit always proceeds without deadlock
- **Kernel-Authoritative Route Model** - Route removal now reads kernel state as source of truth instead of relying solely on the in-memory model, preventing model/kernel divergence
- **Delete-Before-Add Pattern** - Route application now deletes existing entries before adding, eliminating "route already exists" errors during re-application
- **Background DNS Refresh** - Deduplicates kernel operations by destination, uses source-aggregate diffs to prevent false-positive change counts

### Fixed
- **Shell Injection in Route Commands** - Sanitized all inputs to shell route commands
- **XPC Authorization Hardening** - Strengthened privileged helper authorization checks
- **In-Flight Apply Survives Teardown** - Gate-free teardown could clear routes while a concurrent apply was running, which would then overwrite `activeRoutes` with stale data. Epoch counter now lets in-flight operations detect preemption and abort before committing
- **Interface/Tailscale Reroute Race** - VPN interface switch and Tailscale reroute now hold the operation gate across the full remove-then-reapply sequence instead of releasing between operations
- **Mode Switch Safety** - Switching routing modes now holds the gate across the full teardown-and-rebuild cycle with proper precondition checks
- **Stale Route Cleanup** - Two-population cleanup distinguishes truly orphaned routes (re-attach on failure) from add-failed routes (don't re-attach), preventing phantom route accumulation
- **Hosts File Sync on All Mutations** - Adding, toggling, or removing domains now immediately syncs `/etc/hosts` instead of waiting for periodic refresh
- **Multi-IP Hosts Lookup** - Hosts file entries now correctly handle domains that resolve to multiple IPs
- **Scoped Orphan Host Cleanup** - Orphan detection uses a saved domain list, preventing removal of hosts entries that are still needed
- **DNS Cache Persistence for Custom Services** - Custom service DNS resolutions are now cached to disk for instant startup
- **Stale DNS Cache on Import** - Importing a configuration now cleans stale DNS cache entries from removed domains
- **Batch Failure Tracking** - Route batch operations now report per-route success/failure instead of all-or-nothing, with accurate counts in notifications
- **Disconnect Notification Accuracy** - VPN disconnect notification now reports the correct count of routes that couldn't be removed
- **Config Import Reconciliation** - Importing a config now properly reconciles running routes with the new configuration
- **Quit Cleanup** - App quit now properly removes all routes before exiting
- **Bulk Toggle Epoch Safety** - "Enable All"/"Disable All" in domains tab now checks for preemption between each domain operation

## [1.9.2] - 2026-03-29

### Fixed
- **Zscaler Detection in CGNAT Range** - Non-Tailscale CGNAT IPs (100.64.x.x) on VPN interfaces are now accepted without requiring a process-name hint, fixing detection when Zscaler runs newer system extensions like `TRPTunnel` that don't match legacy process patterns (Closes #18)

### Improved
- **Zscaler Process Detection** - Added `TRPTunnel` (transparent proxy system extension) and `UPMServiceController` to recognized Zscaler process names for accurate VPN type identification
- **VPN Detection Logging** - Process hint type is now logged during detection, making it easier to diagnose unrecognized VPN clients

## [1.9.1] - 2026-03-05

Thanks to [@karle0wne](https://github.com/karle0wne) for contributing this release (#16).

### Fixed
- **Tailscale Profile Switch Detection** - Routes are now automatically refreshed when switching Tailscale accounts/profiles while the VPN stays on the same `utun` interface. Previously, stale bypass routes from the old profile would persist until manual refresh (#16)
- **Info Page Version Display** - The About/Info page header showed a hardcoded version instead of reading from the bundle. Now uses `CFBundleShortVersionString` like the rest of the app

### Improved
- **Tailscale CLI Performance** - All Tailscale status queries now use `--self --peers=false`, fetching only the local node's data instead of the entire peer list. Significantly reduces JSON payload and parsing time on large tailnets
- **DRY Tailscale JSON Reading** - Deduplicated Tailscale CLI invocations into a single `readTailscaleStatusJSON()` helper shared across exit node detection, IP checking, and profile fingerprinting

## [1.9.0] - 2026-02-28

### Added
- **Auto-Merge Built-In Service Updates** - App updates now automatically apply new domains, IP ranges, and service names from the latest version while preserving your enabled/disabled preferences. No more stale domain lists after upgrading

### Improved
- **OpenAI / ChatGPT Service** - Added all relevant OpenAI and ChatGPT domains including core properties, auth, CDN, Azure/Cloudflare infrastructure, LiveKit voice, anti-bot, and analytics endpoints

### Fixed
- **Version Display** - App now reads version from the bundle at runtime instead of a hardcoded string, ensuring the displayed version always matches the release (#15)

## [1.8.1] - 2026-02-25

### Fixed
- **Stale Gateway on Domain Addition** - Adding/toggling domains now re-detects the local gateway if stale, instead of silently failing when VPN switches interfaces
- **VPN Interface Switch Not Handled** - Routes are now automatically re-applied when VPN hops interfaces (e.g., utun4 → utun5) while staying connected
- **Network Monitor Missing VPN Changes** - NWPathMonitor now tracks individual interface names, catching VPN interface switches that type-only comparison missed

### Improved
- **No More Silent Failures** - All gateway-dependent actions now log explicit errors when no gateway is available, instead of silently skipping route application
- **Fresh Gateway in All User Actions** - `addDomain`, `toggleDomain`, `toggleService`, `setAllDomainsEnabled`, `setAllServicesEnabled`, and DNS retry all use fresh gateway detection

## [1.8.0] - 2026-02-25

### Added
- **Parallel DNS Resolution** - Dig and DoH now race simultaneously instead of running sequentially. When VPN blocks UDP DNS, DoH wins in ~2s instead of waiting 8+ seconds for dig timeouts first
- **Auto-Retry on DNS Failure** - When adding a domain fails DNS resolution, a 15-second auto-retry is scheduled with cancellation support
- **Immediate Hosts File Update** - Adding or toggling a domain now updates `/etc/hosts` immediately instead of waiting for the periodic refresh

### Fixed
- **Domain Addition Not Bypassing VPN** - Adding a custom domain while connected to VPN now works instantly: DNS cache, disk cache, and hosts file are all populated immediately on success
- **Stale Gateway in Retries** - DNS retry now reads the current gateway instead of using a potentially stale captured value
- **Bulk Enable Disk Thrashing** - "Enable All" no longer writes the DNS cache to disk once per domain; saves once at the end

### Improved
- **DNS Trust Hierarchy** - Trusted dig-based resolvers get a 200ms head start over DoH, preserving CDN locality when local DNS works while still falling back fast on VPN
- **Tracked Retry Tasks** - Retry tasks are now tracked and cancelled on domain removal, VPN disconnect, or route cleanup
- **Consistent State Management** - Removed redundant `MainActor.run` wrappers inside already-MainActor tasks; `isApplyingRoutes` properly set during retries

## [1.7.1] - 2026-02-24

### Fixed
- **Zscaler Detection** - Zscaler (and Cloudflare WARP) use CGNAT IPs (`100.64.x.x`) which were incorrectly treated as Tailscale-only, causing `valid=false` rejection. Now trusts the process-detection hint to distinguish Zscaler/WARP from Tailscale in the shared CGNAT range.

## [1.7.0] - 2026-02-22

### Added
- **Check Point VPN Detection** - Detects Check Point Endpoint Security VPN via process signatures (`Endpoint_Security_VPN`, `TracSrvWrapper`, `cpdaApp`, `cpefrd`)

### Fixed
- **Homebrew Tap Command** - Fixed `brew tap geiserx/tap` (repo doesn't exist) to `brew tap geiserx/vpn-bypass`
- **Stale Repository URLs** - Updated all remaining `vpn-macos-bypass` references to `VPN-Bypass` across README, issue templates, cask, and settings

## [1.6.11] - 2026-02-05

### Improved
- **Better URL Cleaning** - Enhanced domain input parsing when adding custom domains
  - Strips any protocol scheme (http, https, ssh, ftp, and any other `scheme://` format)
  - Removes port numbers (e.g., `:443`, `:8080`)
  - Removes authentication info (e.g., `user:pass@`)
  - Removes paths and query strings
  - Now you can paste full URLs and the domain will be extracted correctly

## [1.6.10] - 2026-01-29

### Fixed
- **VPN Detection Reliability** - Rewrote interface detection with two-pass approach
  - Collects ALL interfaces first, then validates (more robust than single-pass)
  - Better debug logging shows exactly which VPN candidates were found
  - Ensures hasUpFlag is correctly tracked per-interface

## [1.6.9] - 2026-01-28

### Fixed
- **Critical: GCD Thread Pool Exhaustion** - Fixed ifconfig timeouts after extended runtime
  - Replaced nested GCD dispatch + semaphore pattern that caused thread starvation
  - Uses dedicated process queue to isolate process execution
  - Uses polling-based timeout instead of nested dispatch
  - Prevents the "ifconfig command failed/timed out" issue that blocked VPN detection

## [1.6.8] - 2026-01-26

### Added
- **Watchdog Timer** - Restarts network monitor every 12 hours to prevent stale state during long uptimes
- **Uptime Tracking** - Logs app uptime and VPN status during watchdog checks

## [1.6.7] - 2026-01-26

### Fixed
- **Improved VPN Detection Logging** - Better diagnostic logging when VPN detection fails

## [1.6.6] - 2026-01-23

### Changed
- **Rebranded to VPN Bypass** - Release names and DMG files now use "VPN Bypass" / "VPN-Bypass" naming
- **Updated GitHub URLs** - All links now point to the renamed repository

## [1.6.5] - 2026-01-22

### Added
- **DoH Fallback** - Uses DNS over HTTPS (Cloudflare, Google) when regular DNS fails, bypassing VPN DNS hijacking
- **getaddrinfo Timeout** - 3 second timeout prevents hanging on unresponsive system resolver

## [1.6.4] - 2026-01-22

### Added
- **DNS Retry Logic** - Retries DNS resolution once (300ms delay) before giving up
- **System Resolver Fallback** - Uses macOS getaddrinfo() as last resort when dig fails
- **Background Hosts Update** - Hosts file now updated after successful background DNS refresh

## [1.6.3] - 2026-01-22

### Fixed
- **Light Mode Dropdown Visibility** - Background colors now visible in both light and dark modes
- **Hosts File Fallback** - Uses disk cache for hosts file entries when DNS fails at startup

## [1.6.2] - 2026-01-21

### Fixed
- **Remove Stale IPs on Refresh** - Auto DNS refresh now removes IPs that are no longer resolved (was only adding, never removing)

## [1.6.1] - 2026-01-21

### Fixed
- **Deduplicate Routes** - Multiple domains resolving to the same IP no longer create duplicate routes

## [1.6.0] - 2026-01-21

### Added
- **Instant Startup** - If DNS cache exists, applies routes immediately (~2-3s) then refreshes DNS in background
- **DNS Disk Cache** - Resolved IPs are saved to disk and used as fallback when DNS fails
- **Faster Service Toggle** - Enabling a service now resolves all domains in parallel + batch route addition

### Changed
- **Smarter DNS Timeouts** - Local DNS (192.168.x.x, 10.x.x.x): 1s timeout; External DNS: 1.5s timeout
- DNS cache stored at `~/Library/Application Support/VPNBypass/dns-cache.json`

## [1.5.5] - 2026-01-21

### Fixed
- Removed debug logging code from 1.5.4

## [1.5.3] - 2026-01-21

### Fixed
- **Prevent Double Route Application** - Added guard to skip duplicate route application within 5 seconds
- **Fixed Invalid Default Domains** - Removed non-resolving domains: `twimg.com` → `pbs.twimg.com`, `cdninstagram.com` → `scontent.cdninstagram.com`, `api.signal.org` → `chat.signal.org`

### Changed
- **Faster DNS Timeouts** - Reduced DNS timeout from 4s to 2s (1s dig timeout)
- **Larger Batch Size** - Increased from 50 to 100 domains per parallel batch
- **Faster DoH/DoT** - Reduced timeout from 5s to 3s

## [1.5.2] - 2026-01-21

### Fixed
- **True Parallel DNS** - Fixed thread blocking in DNS resolution (was using sync calls that blocked cooperative threads)
- **Auto-Update Helper** - App now detects helper version mismatch and auto-updates (was only installing on first launch)

### Changed
- DNS resolution now uses `DispatchQueue.global()` for true GCD parallelism

## [1.5.1] - 2026-01-21

### Fixed
- **Massive Performance Improvement** - Route application reduced from 3-5 minutes to ~10 seconds
- **True Parallel DNS Resolution** - Fixed `@MainActor` serialization that was blocking parallel execution
- **Batch Route Operations** - Routes now added/removed via single XPC call instead of 300+ individual calls
- **DNS Cache for Hosts File** - Eliminated duplicate DNS resolution (was resolving all domains twice)
- **Increased DNS Batch Size** - From 5 to 50 domains per parallel batch

### Changed
- Helper version bumped to 1.2.0 (will auto-reinstall on first launch)
- DNS resolution functions now `nonisolated static` for true concurrency

## [1.3.4] - 2026-01-19

### Fixed
- **DNS Resolution Fallback** - Now falls back to system DNS if detected DNS fails
- **Reduced Log Spam** - Individual resolution failures no longer spam logs; shows summary instead
- **Faster DNS Queries** - Added timeout flags to dig (+time=2, +tries=1)

## [1.3.3] - 2026-01-19

### Fixed
- **App Icon** - Official logo now shows in Finder, Launchpad, and Dock

## [1.3.2] - 2026-01-19

### Fixed
- **Parallel DNS Resolution** - Route setup now resolves domains in parallel (much faster)
- **No More "Setting Up" Stuck** - VPN connection no longer hangs on route application
- **Route Count Display** - Menu bar now shows route count reliably after VPN connects

## [1.3.1] - 2026-01-18

### Fixed
- **Settings First Click** - Settings window now opens reliably on first gear click
- **Pre-warm Controller** - SettingsWindowController initialized at launch for instant response

## [1.3.0] - 2026-01-18

### Added
- **Silent Notifications** - Option to disable notification sounds
- **Service/Domain Notifications** - Notify when services or domains are toggled (when Routes enabled)
- **DNS Refresh Notifications** - Notify when DNS refresh completes with route updates

### Changed
- **Route Notifications OFF by Default** - Less noisy for most users; enable in Settings for verbose feedback
- **Simplified Notification UI** - Added "Silent" toggle and helper text explaining Routes scope

## [1.2.1] - 2026-01-18

### Added
- **AGENTS.md** - AI agent instructions for development assistance

### Changed
- **Homebrew Auto-Update** - Release workflow now pushes directly to homebrew tap (like LynxPrompt)
- **CI Improvements** - Added HOMEBREW_TAP_TOKEN for automated cask updates

## [1.2.0] - 2026-01-17

### Added
- **Auto DNS Refresh** - Periodically re-resolves domains and updates routes (default: 1 hour)
- **Route Health Dashboard** - View active routes, enabled services, DNS server info in Logs tab
- **Privileged Helper** - One-time admin prompt instead of repeated sudo requests
- **Info Tab** - Author info, support links, and license details in Settings
- **GitHub Community Files** - Issue templates, funding links, contributing guidelines
- **Homebrew Cask** - Install via `brew install --cask vpn-bypass`

### Changed
- **Async Process Execution** - All shell commands now run on background threads (no more UI lag)
- **Incremental Route Updates** - Toggling services/domains only adds/removes affected routes
- **Smarter DNS Resolution** - Respects user's pre-VPN DNS server when available
- **Improved Branding** - Custom logo, "VPN" in blue / "Bypass" in silver throughout app

### Fixed
- UI freezing when applying routes or detecting VPN
- Settings panel now appears above menu dropdown
- Route count updates automatically on startup without manual refresh
- Notifications now appear in System Settings (when app is properly signed)
- Domain removal now actually removes kernel routes

## [1.1.0] - 2026-01-14

### Added
- **Extended VPN Detection** - Fortinet FortiClient, Zscaler, Cloudflare WARP, Pulse Secure, Palo Alto
- **Network Monitoring** - Improved detection when switching WiFi networks
- **Notifications** - Alerts when VPN connects/disconnects and routes are applied
- **Route Verification** - Ping tests to verify routes are actually working
- **Import/Export Config** - Backup and restore your domains and services
- **Launch at Login** - Option to start automatically when you log in

### Changed
- Better VPN interface detection logic
- Improved Tailscale exit node detection

### Fixed
- False positive VPN detection for Tailscale mesh networking
- Gateway detection on some network configurations

## [1.0.0] - 2026-01-10

### Added
- Initial release
- Menu bar app with VPN status and controls
- Pre-configured services: Telegram, YouTube, WhatsApp, Spotify, Tailscale, Slack, Discord, Twitch
- Custom domain support
- Auto-apply routes when VPN connects
- Hosts file management for DNS bypass
- Activity logs
- Settings UI with Domains, Services, General, and Logs tabs
