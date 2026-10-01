# Troubleshooting

Multi-VPN or proxy setups: **[Coexistence with other VPNs and proxies](coexistence.md)** explains the selection
and ownership rules, plus the commands to see what is actually happening.

## App won't open / "damaged" error (macOS Gatekeeper)

The app is ad-hoc signed and not notarized with Apple, so macOS Gatekeeper may block it on first launch. You'll see errors like *"VPN Bypass is damaged and can't be opened"* or *"Apple cannot check it for malicious software"*.

**Fix:** Remove the quarantine attribute:

```bash
xattr -cr /Applications/VPN\ Bypass.app
```

**Prevention:** Install with the `--no-quarantine` flag:

```bash
brew install --cask --no-quarantine vpn-bypass
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
