# Routing modes

VPN Bypass has three modes. Switch from the mode track in the dropdown or from the mode cards at the top of the Settings sidebar; both show the three modes with what each does. Both ask before they switch, because the mode changes how all traffic is routed. The dropdown asks with an alert. Settings opens a sheet that explains each mode and says what your lists hold for it.

## The three modes

- **Bypass** *(default)*: everything uses the VPN as usual, and only the domains/services you list are routed *around* it to your regular connection. Best when your VPN carries all traffic but a few apps misbehave through it.
- **VPN Only**: the inverse: your regular connection is the default, and only the domains/services you list are forced *through* the VPN. Best for a mostly-direct machine with a few things tunneled.
- **Custom**: a per-rule engine: you define **routes** (egresses) and **rules** that map traffic to them. Rules are evaluated top-to-bottom, first match wins, with a pinned "everything else → default" rule. This is what unlocks multi-VPN, proxy, and Tailscale-peer routing.

**Bypass and VPN Only work exactly as they did in earlier versions** — if that's all you need, nothing changes. Custom mode is entirely opt-in.

### Routes and rules (Custom mode)

A **route** is a place traffic can exit:

| Route type | Traffic exits via |
|------------|-------------------|
| **Direct** | your local gateway (around the VPN) |
| **VPN** | a specific VPN interface — pick *which* tunnel when several are up (multi-VPN) |
| **HTTP / SOCKS5 proxy** | a local `127.0.0.1` listener that forwards to your proxy |
| **Tailscale peer** | out through a chosen Tailscale device used as an exit |
| **Block** | nowhere: the names a rule sends here get no answer, and the addresses it names are unreachable (ads, trackers, a country) |

A **rule** maps traffic to a route by `domain`, `suffix`, `ip`, `cidr`, `service`, `geoip`, `geosite`, or `process`. A `process` rule names an app, by its bundle id (`com.example.App`) or its executable's name (`Example`), never a path or a wildcard; [per-app routing](how-it-works.md#per-app-routing) serves it when that is on and the rule's route is Direct; otherwise it routes nothing, and the Rules page, `vpnb rule.list` and `vpnb rule.add` say why. The first matching rule wins; anything unmatched takes the **default** route. Direct and detected VPN routes appear automatically; proxy and Tailscale-peer routes are ones you add.

#### GeoIP and GeoSite rules

Two rule types use the lists that OpenWrt Passwall2, Xray and v2ray publish, so one rule can stand for a whole country or a whole company:

- A **GeoIP** rule (`geoip`) names a list in a `geoip.dat`: a country by its two-letter code (`ir`, `ru`, `cn`) or another list such as `private`, `telegram` or `cloudflare`. It sends the list's IPv4 ranges to the rule's route: one rule, "Iran → Direct", in place of about 2,000 CIDR rules.
- A **GeoSite** rule (`geosite`) names a list in a `geosite.dat`: `category-games`, `steam`, `microsoft`, `openai`, `netflix` and about 1,500 others. A `steam@cn` pattern keeps only the entries carrying that attribute. It sends the list's domains to the route.

Add either on the Rules page. The **GeoIP** and **GeoSite** choices of the Add Rule sheet open a list you search by name (or by country, for GeoIP) instead of asking for a code, and show how many ranges or domains each holds. From the command line: `vpnb rule.add match=geoip pattern=ir routeId=<uuid>` and `vpnb rule.add match=geosite pattern=category-games routeId=<uuid>`.

How a GeoSite list is routed. Routing is per IP, so a domain list needs the same help a wildcard does:

- A `domain` entry of the list (`steampowered.com`, which covers the name and everything under it) becomes a wildcard, served by the helper's DNS forwarder as described in [Wildcards](how-it-works.md): the addresses it answers get routes before the app connects. Wildcards need a Direct route or a VPN route pinned to one tunnel; a list on a proxy route, or on the primary VPN (which needs no route), makes none.
- A `full` entry is one name, resolved like a Domains entry.
- `keyword` and `regex` entries cannot be turned into either, so they are left out; the row says how many.
- An entry already covered by a shorter suffix of the same list is dropped (`store.steampowered.com` after `steampowered.com`).
- First match still holds: a name an earlier rule claims stays with that rule.
- A list of more than 10,000 wildcards (or 2,000 exact names) cannot be served by wildcards, because each wildcard is a file in `/etc/resolver` and a part of a list would send some of a site's names one way and some another. Such a list is refused whole and its row says so. On the **Block** route its exact names become wildcards too, so there the limit is on both together. All lists together share the same 10,000, so two large lists cannot double the number of files: a list that would pass the total is left out whole. The helper refuses more than 12,000 wildcards in all, so the app never sends more: the wildcards of your own rules count first, then the lists in rule order, and a list that no longer fits is left out whole. A rule left out claims nothing, so a later rule still gets its names, and its row says why. A wildcard with more than 64 names under it that earlier rules take is left out too, on any route, and its rule's row and the log say so. Of the lists in the default source's file, `category-games` (953 wildcards and 96 names), `microsoft` (616 and 16) and `steam` (42 and 18) fit; `category-ads-all` (about 200,000) and `geolocation-!cn` are too large. Blocking a list that large belongs to a DNS filter, not to wildcards.

Where the lists come from. They are downloaded the first time a rule needs one (unless Sync is Off), then on the Sync schedule below: at launch, after a config save, and every 12 hours while the app runs, a list older than the schedule is downloaded again, and a failed download is tried again an hour later. This is the only data the app downloads. The Rules page, and the Add Rule sheet, show where each list comes from, with a **Source** menu: Loyalsoldier (the default, the list OpenWrt Passwall2 uses), Chocolate4U's Iran list (the same lists with Iranian ones added), MetaCubeX and runetfreedom's Russia list, or **Custom URL…** for an https address of your own (a mirror, say, where GitHub is blocked). Picking a source downloads from it at once. In `config.json` they are `geoipSourceURL` and `geositeSourceURL`.

- Whoever serves a list decides what the rules route; the source is named on the Rules page for that reason.
- A download replaces the list in use only when it reads as a list of its kind (a geosite file is not accepted as a geoip one); an error page, a truncated file or one over 160 MB leaves the last good copy in place. Each preset publishes a `.sha256sum` file next to each list, and a download that does not match it, or whose checksum cannot be downloaded, is refused the same way. A custom address is checked too when it has one; a list from one that publishes none is used, and the status line under the list says it was not checked. A whole download may take 5 minutes at most.
- GeoIP ranges become kernel routes, one per range, as the same number of CIDR rules would. A country of more than 50,000 ranges (the default list has about 127,000 for the US, and about 30,000 for Germany) is refused whole and its row says so, never cut short: a part of a country would send some of it one way and some another. All Country rules together route at most 100,000 ranges: countries count in rule order, and one that would pass the total is left out whole, with its row saying so (the five largest countries under the limit add up to about 136,000). A downloaded list is held to more than a CIDR you type, so a broken or hostile list cannot take over the routing table or reach the Mac's own networks: a range shorter than `/8` is left out (no country goes below it; the US has one `/7`, which is left out), and so is private, loopback, link-local, carrier-grade NAT, multicast and reserved space, except in the `private` list. The row counts only the ranges that are routed, and says how many were left out. Only IPv4 is used, and the rows say so: a country's IPv6 addresses are neither routed nor blocked.
- Until a list has been downloaded, its rules route nothing, and their rows say so.
- The files are kept in Application Support (`geoip.dat`, `geosite.dat`), readable by your account only.

The **Rules** page shows, under the list, when each list was last synced (the time and how long ago), where it comes from, how often it is downloaded again, and a **Sync Now** button. **Sync** is Off, Every day, Every week (the default) or Every month, one setting for both lists (`geoSync` in `config.json`); Off downloads nothing by itself, not even a list that is missing, and leaves it to Sync Now. The Add Rule sheet shows the same controls under the picker.

#### The Block route

A **Block** route is a blackhole, as in OpenWrt Passwall2. A rule that sends names to it (a `suffix`, `domain` or `service` rule, or a GeoSite list such as an ad or tracker category) makes the helper's DNS forwarder answer those names, and everything under them, with NXDOMAIN, so nothing connects. The upstream is never asked, so no lookup for a blocked name leaves the Mac. Choose **Block** in a rule's route menu (the route is made the first time you do, and taken out again when you change the rules and no rule uses it; Undo of the rule puts it back), or add a route of type Block in Routes under a name of your own, which stays until you delete it, or `vpnb route.add name=Block type=block`. Everything else cannot be Block, on the Rules page or through `vpnb default`.

- It works through the Mac's own DNS, as wildcards do: an app that brings its own, such as a browser with secure DNS, is not blocked, and a name already resolved keeps working until its cache expires.
- First match holds: a rule above a Block rule that claims a name (an allow rule for `ok.ads.example.com`, say) keeps that name.
- An exact name is blocked with what is under it.
- An address a rule names (an `ip`, a `cidr`, a country's GeoIP ranges, a service's ranges) on the Block route is blocked with a reject route in the kernel, the same helper call VPN Only's blocks use: a packet to it fails at once with "no route to host". The row says how many addresses are blocked. First match holds as for routes: an address an earlier rule sends elsewhere, the primary VPN included, is cut out of a blocked range and keeps going there. The addresses a blocked *name* happens to resolve to are left alone, because a CDN address shared with other sites would take them down with it; the DNS answer does the blocking. Only IPv4. A range that holds the gateway, the VPN's gateway or a DNS server the app uses is left out and logged. These blocks follow the rules, not the VPN: they stay while the VPN is down, and a mode switch, a pause, Remove All Routes or a quit takes them out with the other routes.
- A GeoSite list too large for wildcards (see the limits above) is refused whole on the Block route too, and its row says so.
- A name sent to the Block route is never looked up: it is answered NXDOMAIN, so the app's own DNS is not asked about it either.
- Blocking names needs helper 2.10.0, which an updated app installs by itself without a password; until then the Block wildcards are held back and the others keep working. Blocking addresses works with any helper from 2.6.0.

#### Your rules are kept

An update never drops a rule or a route. A config from an earlier version loads whole and saves back with the same rules, routes, services and lists; the new settings take defaults (the sync schedule, the sources) and no route is added to a config that never blocks. A config with a match type or route type this version does not know, written by a newer one, loads too: the rule or route is kept with every field it had (not only the ones this version knows), shown as unknown, matches nothing and carries no traffic, and is written back when you save; only what you can change here (a rule's route, pattern, order and whether it is on; a route's name and whether it is on) changes in it. A version before GeoIP, GeoSite and Block (6.1.1 and earlier) cannot read a config that holds one of them: it routes nothing until the file is fixed, and leaves the file untouched. Before you go back to such a version, export the config and remove those rules and the Block route, or come back to this version or later to use it again. The sync schedule is written only once you change it, so a config that never uses the lists saves as it did before.

A proxy route's `127.0.0.1` listener holds your upstream proxy credentials, so it will not serve a client that cannot prove it is you. Any process on the machine can reach a loopback port, and macOS gives a TCP listener no way to see who connected, so the listener asks for a password instead. Use **Copy Shell Exports** or **Copy Proxy URL** on the route. Both hand you the address with the credentials already in it:

```bash
export HTTPS_PROXY="http://vpnb:<secret>@127.0.0.1:18042"
```

The secret is generated once and kept in the app's config file, which only your account can read. Copy them again if you ever reset your config. A browser takes `127.0.0.1` and the port in its proxy settings and then asks you to sign in: the user is `vpnb`, and the password is the part between `vpnb:` and `@` in the copied proxy URL.
