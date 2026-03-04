# VPN Bypass - Product Roadmap

## Current State (v1.9.0)

### ✅ Phase 1 Complete - Core & Polish (v1.0 - v1.2)

| Feature | Status | Notes |
|---------|--------|-------|
| **Menu Bar App** | ✅ Done | Real-time VPN status, route count, quick controls |
| **Domain-based Bypass** | ✅ Done | Custom domains + 37+ pre-configured services |
| **Route Management** | ✅ Done | Kernel routing table + `/etc/hosts` DNS bypass |
| **VPN Detection** | ✅ Done | GlobalProtect, Cisco, OpenVPN, WireGuard, Fortinet, Zscaler, WARP, Tailscale, Check Point |
| **Network Change Handling** | ✅ Done | NWPathMonitor + debouncing, auto-refresh on wake |
| **Notifications** | ✅ Done | Per-event toggles, silent mode, System Settings integration |
| **Route Verification** | ✅ Done | Ping test (disabled by default - many servers block ICMP) |
| **Import/Export Config** | ✅ Done | JSON export/import in Settings |
| **Launch at Login** | ✅ Done | SMAppService, enabled by default |
| **Privileged Helper** | ✅ Done | No sudo prompts, auto-install + auto-update on version mismatch |
| **Auto DNS Refresh** | ✅ Done | Periodic re-resolution (default 1h), keeps hosts file fresh |
| **Loading States** | ✅ Done | Spinner during route operations, UI blocking |
| **Incremental Routes** | ✅ Done | Toggle single service/domain without full rebuild |
| **Bulk Operations** | ✅ Done | All/None for services and domains |
| **Respect User's DNS** | ✅ Done | Detects pre-VPN DNS from primary interface |
| **Homebrew Cask** | ✅ Done | `brew install --cask vpn-bypass` with auto-update CI |
| **Route Health Dashboard** | ✅ Done | Active routes, services, domains, DNS server, timing in Logs tab |

### ✅ Phase 1.5 Complete - Performance & Reliability (v1.3 - v1.6)

| Feature | Status | Notes |
|---------|--------|-------|
| **Instant Startup** | ✅ Done | DNS disk cache enables routes in ~2-3s, background refresh |
| **True Parallel DNS** | ✅ Done | Dig + DoH race simultaneously; VPN-blocked DNS falls back in ~2s |
| **Batch Route Operations** | ✅ Done | Single XPC call instead of 300+ individual calls (3-5min → ~10s) |
| **DoH Fallback** | ✅ Done | Cloudflare + Google DNS over HTTPS when regular DNS fails |
| **DoT Support** | ✅ Done | DNS over TLS as additional resolution method |
| **DNS Disk Cache** | ✅ Done | Persists resolved IPs, fallback when DNS fails |
| **Auto-Retry on DNS Failure** | ✅ Done | 15s retry with cancellation support |
| **12-Hour Watchdog** | ✅ Done | Restarts network monitor to prevent stale state on long uptimes |
| **GCD Thread Pool Fix** | ✅ Done | Eliminated thread starvation causing ifconfig timeouts |
| **VPN Two-Pass Detection** | ✅ Done | Collects ALL interfaces first, then validates |
| **URL Input Cleaning** | ✅ Done | Paste full URLs, strips protocol/port/path/auth automatically |
| **SOCKS5 Proxy** | ✅ Done | Aggressive bypass for corporate VPNs blocking UDP |
| **Light/Dark Mode** | ✅ Done | Full compatibility for dropdown and all UI elements |

### ✅ Phase 1.7 Complete - VPN Compatibility & Robustness (v1.7 - v1.9)

| Feature | Status | Notes |
|---------|--------|-------|
| **Check Point VPN** | ✅ Done | Process-based detection for Endpoint Security VPN |
| **Zscaler CGNAT Fix** | ✅ Done | Distinguishes Zscaler/WARP from Tailscale in shared 100.64.x.x range |
| **Tailscale CGNAT Fix** | ✅ Done | No longer misidentified as corporate VPN when GlobalProtect disconnects |
| **Gateway Robustness** | ✅ Done | Re-detects gateway on user actions and VPN interface switches |
| **VPN Interface Hopping** | ✅ Done | Routes re-applied when VPN switches interfaces (utun4 → utun5) |
| **Auto-Merge Service Updates** | ✅ Done | App upgrades apply new domains/IPs while preserving user preferences |
| **OpenAI/ChatGPT Domains** | ✅ Done | Comprehensive domain list including CDN, auth, Azure, LiveKit |
| **Runtime Version Display** | ✅ Done | Reads from bundle, always matches release |

---

## Roadmap

### Phase 2: Advanced Routing (v2.0 - v2.5)

| Feature | Description |
|---------|-------------|
| **App-based Routing** | Bypass VPN for specific apps (Safari, Chrome, Spotify app) |
| **Inverse Mode** | Route ONLY specific traffic through VPN, bypass everything else |
| **Kill Switch** | Block all traffic if VPN disconnects unexpectedly |
| **DNS Leak Protection** | Ensure DNS queries don't leak through VPN |
| **IPv6 Leak Protection** | Block IPv6 to prevent leaks |
| **Connection Profiles** | Different configs for "Home", "Work", "Travel" |
| **Scheduled Rules** | Auto-enable/disable bypasses based on time |
| **Local DNS Proxy** | Run local DNS that uses ISP DNS for bypass domains |

### Phase 3: Power Features (v3.0+)

| Feature | Description |
|---------|-------------|
| **Custom DNS** | Use specific DNS servers for bypassed traffic (DoH/DoT) |
| **Blocklists Integration** | Block ads/trackers/malware domains |
| **Network-based Profiles** | Auto-switch profile based on WiFi SSID |
| **Bandwidth Monitor** | Track data through VPN vs bypassed |
| **CLI Interface** | Command-line control for automation |
| **API/Webhooks** | Integration with other tools |
| **Statistics Dashboard** | Detailed analytics and history |
| **Traffic Verification** | Verify traffic actually goes through correct interface |

### Phase 4: Advanced (v4.0+)

| Feature | Description |
|---------|-------------|
| **Multi-device Sync** | Sync settings across devices via iCloud |
| **MDM Support** | Deployment and management for organizations |
| **Policy Templates** | Pre-built configs for common scenarios |
| **Audit Logging** | Detailed logs for compliance |

---

## Defense-in-Depth Strategy

### Current Protection Layers
1. ✅ **IP Routes** - Kernel routing table bypasses VPN
2. ✅ **Static IP Ranges** - Services like Telegram have known ranges
3. ✅ **Hosts File** - Local DNS override, immune to VPN DNS hijacking
4. ✅ **Auto DNS Refresh** - Catches IP changes within 1 hour
5. ✅ **DNS Disk Cache** - Instant startup + fallback when DNS fails
6. ✅ **DoH/DoT Fallback** - Bypasses VPN DNS hijacking via encrypted DNS
7. ✅ **SOCKS5 Proxy** - Aggressive bypass when VPN blocks UDP

### Future Protection Layers
8. 🔲 **ASN Routing** - Route all IPs owned by a service
9. 🔲 **Multiple DNS** - Query Google + Cloudflare for redundancy
10. 🔲 **Local DNS Proxy** - Intercept and resolve locally
11. 🔲 **Traffic Verification** - Confirm correct interface usage

---

## Competitive Analysis

| App | Platform | Key Features | Pricing |
|-----|----------|--------------|---------|
| **Surfshark Bypasser** | macOS | Per-app/website split tunneling | Part of Surfshark subscription |
| **ProtonVPN** | macOS | Split tunneling, kill switch, custom DNS | Free tier + $4.99/mo |
| **VPN Peek** | macOS | Status monitoring, leak detection | $3.99 one-time |
| **Tunnelblick** | macOS | OpenVPN client, split routing | Free (open source) |

### Our Differentiators
1. **Smart VPN Detection** - Correctly identifies corporate VPNs vs Tailscale mesh
2. **Pre-configured Services** - One-click enable for 37+ popular services
3. **Beautiful UI** - Modern SwiftUI interface
4. **No VPN Required** - Works with ANY VPN, not tied to a provider
5. **Privacy-focused** - No analytics, no cloud dependency
6. **Defense-in-Depth** - Routes + Hosts + DoH + SOCKS5 + Auto-refresh for maximum protection
7. **Instant Startup** - DNS cache enables routes in seconds, not minutes

---

## Community & Visibility

### Awesome Lists

| List | Stars | Status |
|------|-------|--------|
| [serhii-londar/open-source-mac-os-apps](https://github.com/serhii-londar/open-source-mac-os-apps) | 47.7k | ✅ Listed |
| [jaywcjlove/awesome-mac](https://github.com/jaywcjlove/awesome-mac) | 99.5k | PR submitted |
| [dkhamsing/open-source-ios-apps](https://github.com/dkhamsing/open-source-ios-apps) | 49k | PR submitted |
| [matteocrippa/awesome-swift](https://github.com/matteocrippa/awesome-swift) | 26k | PR submitted |
| [jaywcjlove/awesome-swift-macos-apps](https://github.com/jaywcjlove/awesome-swift-macos-apps) | 1.2k | PR submitted |
| [phmullins/awesome-macos](https://github.com/phmullins/awesome-macos) | 3k | PR submitted |

### Other Channels

| Channel | Type | Notes |
|---------|------|-------|
| **Hacker News** | Show HN post | High-impact if it hits front page |
| **Reddit** | r/macapps, r/opensource, r/swift | r/macapps is the most targeted audience |
| **Product Hunt** | Product launch | Good for long-term discoverability |
| **AlternativeTo** | List as alternative to split-tunnel VPNs | Passive SEO traffic |
| **Lobste.rs** | Show post | Dev-heavy audience (invite required) |
| **Swift Forums** | forums.swift.org | "Built with SwiftUI" showcase angle |
| **Dev.to / Medium** | Technical write-up | Split tunneling, route management, SwiftUI |
| **MacStories** | Email tips line | They cover Mac utilities |
| **Homebrew core cask** | Move from tap to homebrew-cask | Massively increases `brew search` discoverability |
| **MacUpdate** | App listing | Still gets traffic for Mac app searches |
| **Slant** | Q&A recommendation | "Best VPN tools for macOS" |

---

## Next Steps

1. ✅ **v1.0 - v1.2**: Core features, notifications, helper, Homebrew
2. ✅ **v1.3 - v1.6**: Performance overhaul, instant startup, DoH/DoT, DNS cache
3. ✅ **v1.7 - v1.9**: VPN compatibility (Check Point, Zscaler, Tailscale), gateway robustness, auto-merge
4. 🔲 **v2.0**: Implement license system + app-based routing (Premium)
5. 🔲 **v2.5**: Kill switch + leak protection + connection profiles (Premium)
6. 🔲 **v3.0**: CLI interface + network profiles + statistics

---

## Technical Debt / Known Issues

- [ ] Helper installation can fail silently on some systems
- [ ] Route verification unreliable (many servers block ICMP)
- [ ] No automated UI tests

---

*Last updated: March 4, 2026*
