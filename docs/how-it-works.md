# How it works

## Supported VPN types

| VPN Client | Detection |
|------------|-----------|
| GlobalProtect | ✅ Full |
| Cisco AnyConnect | ✅ Full |
| OpenVPN | ✅ Full |
| WireGuard | ✅ Full |
| Fortinet FortiClient | ✅ Full |
| Zscaler | ✅ Full |
| Cloudflare WARP | ✅ Full |
| Pulse Secure | ✅ Full |
| Check Point | ✅ Full |
| Tailscale (exit node) | ✅ Full |
| Tailscale (mesh only) | ❌ Not VPN |

## Steps

1. **VPN Detection**: Monitors network interfaces and running processes to detect VPN type
2. **Gateway Detection**: Identifies your local gateway (Wi-Fi/Ethernet router)
3. **Route Management**: A small privileged helper adds/removes host routes to steer traffic per your mode — around the VPN (Bypass), through it (VPN Only), or to the route a rule selects (Custom). The helper is cdhash-pinned to this app and uses no Network Extension entitlements.
4. **Route Verification**: Pings up to 10 routed single addresses (ping cannot test a range) to check they answer, after an apply when that option is on, or from Verify Routes in the menu
5. **DNS Bypass**: Optionally adds entries to `/etc/hosts` to bypass VPN DNS

### VPN Detection Logic

> Running more than one VPN (e.g. a corporate client plus Tailscale), or local proxies? See
> **[Coexistence with other VPNs and proxies](coexistence.md)** for exactly what VPN Bypass will and will not
> touch — one tunnel is acted on, Tailscale is never selected, loopback is never routed.

The app intelligently detects corporate VPNs while avoiding false positives:

| Interface Type | IP Range | Detection |
|---------------|----------|-----------|
| **Corporate VPN** (GlobalProtect, Cisco, etc.) | `10.x.x.x`, `172.16-31.x.x` | ✅ Detected as VPN |
| **Cloudflare WARP** | `100.96-111.x.x` | ✅ Detected as VPN |
| **Tailscale** (mesh networking) | `100.64-127.x.x` | ❌ Not detected* |
| **Tailscale** (exit node active) | `100.64-127.x.x` | ✅ Detected as VPN |

**\*Tailscale in normal mode** only routes traffic to other Tailscale devices. It's not a "full VPN" because your regular internet traffic still goes through your normal connection. The app only considers Tailscale as a VPN when you're using an **exit node** (routing all traffic through another Tailscale device).

The detection also requires:
- The interface must have the `UP` flag (actually connected, not just configured)
- The interface must have an IPv4 address in a VPN range
