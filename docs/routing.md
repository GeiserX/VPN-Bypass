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
- A list of more than 10,000 wildcards (or 2,000 exact names) cannot be served by wildcards, because each wildcard is a file in `/etc/resolver` and a part of a list would send some of a site's names one way and some another. On a Direct or pinned VPN route such a list is refused whole and the row says so. On the **Block** route it is blocked in `/etc/hosts` instead, up to 500,000 names (see The Block route below). Up to 10,000, 10,000 files take about 2 seconds to write and 0.2 seconds to check again, and the helper finds the wildcard for a name by lookup, so a lookup costs the same whatever the size. Of the lists in the default source's file, `category-games` (955 wildcards and 96 names), `microsoft` (624 and 16), `apple` (1,536 and 48), `google` (828 and 19), `steam`, `category-ads` (582 and 133) and `category-ads-and-telemetry` fit; `category-ads-all` (88,639) is blocked in the hosts file on the Block route, and `geolocation-!cn` (24,172 and 135) and `category-ir` (41,819) are too large for a route.

Where the lists come from. They are downloaded the first time a rule needs one, and again when the copy is more than a week old (at launch, after a config save, and every 12 hours while the app runs; a failed download is tried again an hour later). This is the only data the app downloads. The Rules page, and the Add Rule sheet, show where each list comes from, with a **Source** menu: Chocolate4U's Iran list (the default, the same lists with Iranian ones added), Loyalsoldier, MetaCubeX and runetfreedom's Russia list, Loyalsoldier and MetaCubeX also through jsDelivr's mirror, or **Custom URL…** for an https address of your own (a mirror, say, where GitHub is blocked). Picking a source downloads from it at once. In `config.json` they are `geoipSourceURL` and `geositeSourceURL`.

- Whoever serves a list decides what the rules route; the source is named on the Rules page for that reason.
- A download replaces the list in use only when it reads as a list of its kind (a geosite file is not accepted as a geoip one); an error page, a truncated file or one over 160 MB leaves the last good copy in place.
- GeoIP ranges become kernel routes, one per range, as the same number of CIDR rules would. A country of more than 50,000 ranges (the default list has over 225,000 for the US and over 70,000 for Germany) is refused whole and its row says so, never cut short: a part of a country would send some of it one way and some another. A `/0` or `/1` range is left out, as for a CIDR rule, so a list cannot take over the routing table. Only IPv4 is used.
- Until a list has been downloaded, its rules route nothing, and their rows say so.
- The files are kept in Application Support (`geoip.dat`, `geosite.dat`), readable by your account only.

The **Rules** page shows, under the list, when each list was last synced (the time and how long ago), where it comes from, how often it is downloaded again, and a **Sync Now** button. **Sync** is Off, Every day, Every week (the default) or Every month, one setting for both lists (`geoSync` in `config.json`); Off downloads nothing by itself, not even a list that is missing, and leaves it to Sync Now. The Add Rule sheet shows the same controls under the picker.

#### The Block route

A **Block** route is a blackhole, as in OpenWrt Passwall2. A rule that sends names to it (a `suffix`, `domain` or `service` rule, or a GeoSite list such as an ad or tracker category) makes the helper's DNS forwarder answer those names, and everything under them, with NXDOMAIN, so nothing connects. The upstream is never asked, so no lookup for a blocked name leaves the Mac. Choose **Block** in a rule's route menu (the route is made the first time you do), or add a route of type Block in Routes, or `vpnb route.add name=Block type=block`.

- It works through the Mac's own DNS, as wildcards do: an app that brings its own, such as a browser with secure DNS, is not blocked, and a name already resolved keeps working until its cache expires.
- First match holds: a rule above a Block rule that claims a name (an allow rule for `ok.ads.example.com`, say) keeps that name.
- An exact name is blocked with what is under it.
- An address a rule names (an `ip`, a `cidr`, a country's GeoIP ranges, a service's ranges) on the Block route is blocked with a reject route in the kernel, the same helper call VPN Only's blocks use: a packet to it fails at once with "no route to host". The row says how many addresses are blocked. First match holds as for routes. The addresses a blocked *name* happens to resolve to are left alone, because a CDN address shared with other sites would take them down with it; the DNS answer does the blocking. Only IPv4. A range that holds the gateway, the VPN's gateway or a DNS server the app uses is left out and logged. These blocks follow the rules, not the VPN: they stay while the VPN is down, and a mode switch, a pause, Remove All Routes or a quit takes them out with the other routes.
- A GeoSite list too large for wildcards (an ad list of 200,000 names, say) on the Block route is written to a separate section of `/etc/hosts` as `0.0.0.0 name`, through the helper (`updateBlockedHosts`, helper 2.10.0), so there is no practical size limit (up to 500,000 names). Only the listed names are blocked, not their subdomains, because a hosts file has no wildcards. It is written only when **Pin listed names in /etc/hosts** (Settings > General) is on, the switch that lets the app write that file; with it off the row says so. First match holds, a name another line of the file already maps is left as it is, and a name that is not a plain host name (or has no dot, such as `localhost`) is never written. The section is rewritten only when the blocked set changes, is removed with the other routes on a mode switch, a pause, Remove All Routes or a quit, stays across a VPN drop, and a section a crashed run left is removed at the next start when no rule wants it. How macOS performs with a hosts file of 200,000 lines has not been measured.
- A name sent to the Block route is never looked up: it is answered NXDOMAIN, so the app's own DNS is not asked about it either.
- Blocking names needs helper 2.10.0, which an updated app installs by itself without a password; until then the Block wildcards are held back and the others keep working. Blocking addresses works with any helper from 2.6.0.

#### Your rules are kept

An update never drops a rule or a route. A config from an earlier version loads whole and saves back with the same rules, routes, services and lists; the new settings take defaults (the sync schedule, the sources) and no route is added to a config that never blocks. A config with a match type or route type this version does not know, written by a newer one, loads too: the rule or route is kept with every field it had (not only the ones this version knows), shown as unknown, matches nothing and carries no traffic, and is written back when you save; only what you can change here (a rule's route, pattern, order and whether it is on; a route's name and whether it is on) changes in it. A version before GeoIP, GeoSite and Block rejects a config that holds one of them as unreadable and leaves the file untouched, so go back to this version or later to use it again.

A proxy route's `127.0.0.1` listener holds your upstream proxy credentials, so it will not serve a client that cannot prove it is you. Any process on the machine can reach a loopback port, and macOS gives a TCP listener no way to see who connected, so the listener asks for a password instead. Use **Copy Shell Exports** or **Copy Proxy URL** on the route. Both hand you the address with the credentials already in it:

```bash
export HTTPS_PROXY="http://vpnb:<secret>@127.0.0.1:18042"
```

The secret is generated once and kept in the app's config file, which only your account can read. Copy them again if you ever reset your config. A browser takes `127.0.0.1` and the port in its proxy settings and then asks you to sign in: the user is `vpnb`, and the password is the part between `vpnb:` and `@` in the copied proxy URL.
