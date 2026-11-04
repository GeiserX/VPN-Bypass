# Troubleshooting

Multi-VPN or proxy setups: **[Coexistence with other VPNs and proxies](coexistence.md)** explains the selection
and ownership rules, plus the commands to see what is actually happening.

## App won't open / "damaged" error (macOS Gatekeeper)

From 5.1.0 the app is signed with a Developer ID and notarized by Apple, so Gatekeeper opens it. Update to the latest release if you see this.

On the first launch of a release macOS asks once whether to open an app downloaded from the internet; click Open. If instead it says *"VPN Bypass" Not Opened, Apple could not verify "VPN Bypass" is free of malware*, click Done, not Move to Bin. The release itself is fine: the same dialog did not appear for a fresh copy of the same build in our tests, and this is what cleared it:

1. Move the app out of `/Applications` and back (drag it in Finder, or `mv` it in a terminal), then open it again.
2. If the dialog returns, delete the app and reinstall it from the release DMG, or run `brew reinstall --cask vpn-bypass`.

To confirm the copy you have is the notarized release, run `spctl -a -vv -t exec "/Applications/VPN Bypass.app"`; it answers `accepted`, `source=Notarized Developer ID`.

Earlier versions were signed ad hoc and not notarized, so Gatekeeper could block them on first launch with *"VPN Bypass is damaged and can't be opened"* or *"Apple cannot check it for malicious software"*. On those, remove the quarantine attribute:

```bash
xattr -cr /Applications/VPN\ Bypass.app
```

## Routes not being applied

1. Check if VPN is actually connected (look for utun interface)
2. Check that Settings → Status shows a gateway under Normal connection
3. In Settings → Logs, pick Warnings to see the warnings and errors
4. Use "Verify Routes" button to test connectivity

## Hosts file not updating

The app will prompt for admin password when modifying `/etc/hosts`. If you deny, disable this feature in Settings → General.

## DNS still going through VPN

Some VPNs force DNS through the tunnel. The hosts file entries help bypass this, but you may also need to:
- Disable "Route all DNS through VPN" in your VPN client
- Use a local DNS resolver

## Proxy route returns `407 Proxy Authentication Required`

Your `HTTP(S)_PROXY` is pointing at the listener without its credentials — usually an address copied before you upgraded. Open the route and use **Copy Shell Exports** (or **Copy Proxy URL**) again, then re-source it wherever you keep it. The plain `http://127.0.0.1:<port>` form no longer works, by design: without it, any other account on the machine could spend your upstream proxy credentials.

## Route verification failing

If routes are applied but verification fails, the card says why:
- "Went into utun4": the address left through the VPN although its route sends it around. Refresh Routes, and check that no other VPN or filter claims it.
- "No answer on 443 via en0": the route is right, but nothing answered on port 443. The host may not serve HTTPS on that address; try the service directly.
- "Check broken": the control address left through another tunnel than the one it should take, so the check could not tell the two ways apart. A split-tunnel VPN, which carries only some networks and leaves the default route on the physical interface, is not reported as broken: each address is judged by its own route, and `vpnb why` says that an address such a VPN does not carry leaves around it even without the entry.
- `vpnb why <host>` says which entry routes a site and runs the same check on it.

## Per-app routing

What it does and what it leaves to the routes: [How it works](how-it-works.md#per-app-routing). Turning it off in Settings > General (or `vpnb engine.off`) takes it out of the way completely and leaves the app as it is without it, so that is the first step whenever you suspect it.

### A listed app still uses the VPN

Settings > General > Per-app routing says why in its status line, and `vpnb engine.status` gives the same state as a code. The usual reasons:

- it is off, waiting for one of the two approvals, paused, or stopped after a crash: the line says which;
- you are in VPN Only mode, or the VPN sends every connection into its tunnel (`includeAllNetworks` or `enforceRoutes`), which no app can get around;
- the app's connection went to an IPv6, local or private address, or used UDP: only TCP to public IPv4 addresses is taken;
- the app bound its connection to a network interface itself: the group counts those as "bound to a network interface", and they keep their route;
- in Custom mode, the rule for the app is not the first rule that matches it, or its route is not Direct.

A VPN that sends everything into its tunnel with two routes (`0.0.0.0/1` and `128.0.0.0/1`) without becoming the Mac's main network service, as `wg-quick` does, can leave the physical interface with no route of its own. Connections tied to that interface then cannot connect, so the extension stops taking them for 30 seconds at a time and the app goes through the VPN instead.

### Every new connection hangs for about 5 seconds

That is what macOS does once when the extension crashes: it holds new TCP connections for about 5 seconds, then lets them through without it. The app starts the extension again once; a second crash within 10 minutes turns per-app routing off, and Settings > General says so. If it keeps happening, turn per-app routing off.

### Remove the per-app routing extension

Turning per-app routing off removes its configuration and its extension; macOS asks for your administrator password once. If you cancel that prompt, the configuration is already gone, so no connection passes through the extension any more, and **Remove Extension** in Settings > General (or `vpnb engine.remove`) asks again. When the removal finishes, `systemextensionsctl list` shows `com.geiserx.vpn-bypass.proxy` as `[terminated waiting to uninstall on reboot]`, or no longer lists it.

Homebrew cannot remove a system extension: `brew uninstall` deletes the app and leaves the extension running. Turn per-app routing off first. If the app is already gone, either install it again, open Settings > General and click Remove Extension, or do it by hand:

1. System Settings > Network > Filters & Proxies (VPN & Filters on older versions of macOS; search System Settings for "Filters" if it is elsewhere): select **VPN Bypass per-app routing** and remove it. From then on no connection passes through the extension.
2. System Settings > General > Login Items & Extensions > Network Extensions: switch **VPN Bypass** off, with your administrator password.
3. Restart the Mac. `systemextensionsctl list` should no longer show `com.geiserx.vpn-bypass.proxy` as `activated`.

