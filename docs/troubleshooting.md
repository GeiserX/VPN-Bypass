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

If routes are applied but verification fails:
- The destination host may be blocking ping (ICMP)
- Try accessing the service directly - it may still work
- Check if the service is actually accessible from your network
