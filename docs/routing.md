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

A **rule** maps traffic to a route by `domain`, `suffix`, `ip`, `cidr`, `service`, `geoip`, or `process`. A `process` rule names an app, by its bundle id (`com.example.App`) or its executable's name (`Example`), never a path or a wildcard; [per-app routing](how-it-works.md#per-app-routing) serves it when that is on and the rule's route is Direct; otherwise it routes nothing, and the Rules page, `vpnb rule.list` and `vpnb rule.add` say why. The first matching rule wins; anything unmatched takes the **default** route. Direct and detected VPN routes appear automatically; proxy and Tailscale-peer routes are ones you add.

#### Country (GeoIP) rules

A `geoip` rule names a list in a `geoip.dat` file, usually a country by its two-letter code (`ir`, `ru`, `cn`), and sends that list's IPv4 ranges to its route: one rule, "Iran → Direct", instead of one CIDR rule per range. Add it on the Rules page with **Country**, or with `vpnb rule.add match=geoip pattern=ir routeId=<uuid>`. The list also holds names such as `private`, and the Choose… menu of the editor lists every one in the file with its number of ranges.

The list is a `geoip.dat` in the format OpenWrt Passwall2, Xray and v2ray read. It is downloaded the first time a Country rule needs it, and again when it is more than a week old (at launch, after a config save, and every 12 hours while the app runs; a failed download is tried again an hour later). This is the only data the app downloads. The default source is [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat); to use another one, such as a mirror where GitHub is blocked, [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat), [Chocolate4U/Iran-v2ray-rules](https://github.com/Chocolate4U/Iran-v2ray-rules) or [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat), set `geoipSourceURL` in `config.json` to its https URL. The Rules page shows the source and the age of the list, with an **Update** button, while a Country rule is on.

- A download replaces the list in use only when it reads as a geoip list; an error page, a truncated file or one over 64 MB leaves the last good copy in place.
- The ranges become kernel routes, one per range, as the same number of CIDR rules would. A `/0` or `/1` range in a list is left out, as it is for a CIDR rule, so a list cannot take over the routing table.
- Only IPv4 ranges are used. A list entry marked as "everything except" is skipped.
- Until the list has been downloaded, a Country rule routes nothing, and its row says so. A config with a Country rule cannot be read by a version before this one, which rejects an unknown match type.
- The file is kept in Application Support (`geoip.dat`), readable by your account only.

A proxy route's `127.0.0.1` listener holds your upstream proxy credentials, so it will not serve a client that cannot prove it is you. Any process on the machine can reach a loopback port, and macOS gives a TCP listener no way to see who connected, so the listener asks for a password instead. Use **Copy Shell Exports** or **Copy Proxy URL** on the route. Both hand you the address with the credentials already in it:

```bash
export HTTPS_PROXY="http://vpnb:<secret>@127.0.0.1:18042"
```

The secret is generated once and kept in the app's config file, which only your account can read. Copy them again if you ever reset your config. A browser takes `127.0.0.1` and the port in its proxy settings and then asks you to sign in: the user is `vpnb`, and the password is the part between `vpnb:` and `@` in the copied proxy URL.
