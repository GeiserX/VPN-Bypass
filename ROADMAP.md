# VPN Bypass - Product Roadmap

## Current State (v1.1)

### ✅ Phase 1 Complete - Polish & Stability

| Feature | Status | Notes |
|---------|--------|-------|
| **Improved VPN Detection** | ✅ Done | GlobalProtect, Cisco, OpenVPN, WireGuard, Fortinet, Zscaler, Cloudflare WARP, Tailscale exit node |
| **Network Change Handling** | ✅ Done | NWPathMonitor + debouncing, auto-refresh on wake |
| **Notifications** | ✅ Done | UNUserNotificationCenter, per-event toggles, appears in System Settings |
| **Route Verification** | ✅ Done | Ping test (disabled by default - many servers block ICMP) |
| **Import/Export Config** | ✅ Done | JSON export/import in Settings |
| **Launch at Login** | ✅ Done | SMAppService, enabled by default |
| **Privileged Helper** | ✅ Done | No sudo prompts, auto-install on first launch |
| **Auto DNS Refresh** | ✅ Done | Periodic re-resolution (default 1h), keeps hosts file fresh |
| **Loading States** | ✅ Done | Spinner during route operations, UI blocking |
| **Incremental Routes** | ✅ Done | Toggle single service/domain without full rebuild |
| **Bulk Operations** | ✅ Done | All/None for services and domains |

### ✅ Core Features (v1.0)
- Menu bar app with real-time VPN status
- Domain-based bypass rules
- Pre-configured services (37 services: Telegram, YouTube, WhatsApp, Spotify, Netflix, etc.)
- Route management via system routing table
- Optional `/etc/hosts` management for DNS bypass
- Settings UI with Domains, Services, General, Logs tabs
- Activity logging with copy functionality

---

## Roadmap

### Phase 1.2: DNS & Distribution (v1.2) ✅ COMPLETE
**Completed: January 2026**

| Feature | Status | Notes |
|---------|--------|-------|
| **Respect User's DNS** | ✅ Done | Detects pre-VPN DNS from primary interface, uses for all resolution |
| **Homebrew Tap** | ✅ Done | `brew tap geiserx/vpn-bypass && brew install --cask vpn-bypass` |
| **Route Health Dashboard** | ✅ Done | Shows active routes, services, domains, DNS server, timing info in Logs tab |

**Note**: ASN-based routing considered but deferred - current hardcoded IP ranges + DNS resolution is sufficient.

### Phase 2: Advanced Routing (v1.3 - v1.5)
**Timeline: 3-6 months**

| Feature | Description | Tier |
|---------|-------------|------|
| **App-based Routing** | Bypass VPN for specific apps (Safari, Chrome, Spotify app) | **Premium** |
| **Inverse Mode** | Route ONLY specific traffic through VPN, bypass everything else | **Premium** |
| **Kill Switch** | Block all traffic if VPN disconnects unexpectedly | **Premium** |
| **DNS Leak Protection** | Ensure DNS queries don't leak through VPN | **Premium** |
| **IPv6 Leak Protection** | Block IPv6 to prevent leaks | **Premium** |
| **Connection Profiles** | Different configs for "Home", "Work", "Travel" | **Premium** |
| **Scheduled Rules** | Auto-enable/disable bypasses based on time | **Premium** |
| **Local DNS Proxy** | Run local DNS that uses ISP DNS for bypass domains | **Premium** |

### Phase 3: Power Features (v2.0+)
**Timeline: 6-12 months**

| Feature | Description | Tier |
|---------|-------------|------|
| **Custom DNS** | Use specific DNS servers for bypassed traffic (DoH/DoT) | **Premium** |
| **Blocklists Integration** | Block ads/trackers/malware domains | **Premium** |
| **Network-based Profiles** | Auto-switch profile based on WiFi SSID | **Premium** |
| **Bandwidth Monitor** | Track data through VPN vs bypassed | **Premium** |
| **CLI Interface** | Command-line control for automation | **Premium** |
| **API/Webhooks** | Integration with other tools | **Enterprise** |
| **Statistics Dashboard** | Detailed analytics and history | **Premium** |
| **Traffic Verification** | Verify traffic actually goes through correct interface | **Premium** |

### Phase 4: Enterprise & Advanced (v3.0+)
**Timeline: 12+ months**

| Feature | Description | Tier |
|---------|-------------|------|
| **Multi-device Sync** | Sync settings across devices via iCloud | **Premium** |
| **MDM Support** | Enterprise deployment and management | **Enterprise** |
| **Policy Templates** | Pre-built configs for common scenarios | **Enterprise** |
| **Audit Logging** | Detailed logs for compliance | **Enterprise** |
| **Custom Branding** | White-label for enterprises | **Enterprise** |
| **Priority Support** | Dedicated support channel | **Enterprise** |

---

## Defense-in-Depth Strategy

### Current Protection Layers
1. ✅ **IP Routes** - Kernel routing table bypasses VPN
2. ✅ **Static IP Ranges** - Services like Telegram have known ranges
3. ✅ **Hosts File** - Local DNS override, immune to VPN DNS hijacking
4. ✅ **Auto DNS Refresh** - Catches IP changes within 1 hour

### Future Protection Layers
5. 🔲 **ASN Routing** - Route all IPs owned by a service
6. 🔲 **Multiple DNS** - Query Google + Cloudflare for redundancy
7. 🔲 **Local DNS Proxy** - Intercept and resolve locally
8. 🔲 **Traffic Verification** - Confirm correct interface usage

---

## Feature Tiers

### 🆓 Free Tier
Core functionality for individual users:
- VPN detection and status display
- Up to **5 custom domains**
- Up to **3 pre-configured services**
- Basic route management
- Activity logs (last 24 hours)
- Community support

### 💎 Premium Tier ($9.99 one-time or $4.99/year)
Full power for power users:
- **Unlimited** domains and services
- App-based routing (bypass specific apps)
- Inverse mode (route only specific traffic)
- Kill switch and leak protection
- Connection profiles
- Custom DNS for bypassed traffic
- Scheduled rules
- Unlimited log history
- Email support

### 🏢 Enterprise Tier ($49/year per seat)
For teams and organizations:
- Everything in Premium
- Multi-device sync
- MDM/deployment support
- Policy templates
- Audit logging
- API access
- Priority support
- Custom branding option

---

## Licensing Implementation Options

### Option 1: Gumroad (Simplest)
- One-time purchase with license key
- User enters key in Settings
- App validates key via Gumroad API
- Pros: Easy to set up, handles payments
- Cons: No subscription management built-in

### Option 2: LemonSqueezy (Modern)
- Supports one-time and subscriptions
- Built-in license key generation
- Webhook support for real-time validation
- Pros: Modern API, good for subscriptions
- Cons: Newer platform

### Option 3: Paddle (Professional)
- Full-featured payment platform
- Handles taxes globally
- Mac App Store alternative
- Pros: Professional, handles compliance
- Cons: More complex setup

### Recommended Approach
1. **Start with Gumroad** for quick launch
2. Migrate to **LemonSqueezy** when you need subscriptions
3. Consider **Paddle** for enterprise/international

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
6. **Defense-in-Depth** - Routes + Hosts + Auto-refresh for maximum protection

---

## Next Steps

1. ✅ **v1.1**: Completed - notifications, helper, DNS refresh, loading states
2. 🔲 **v1.2**: Config migration, ASN routing, Homebrew tap
3. 🔲 **v1.3**: Implement license system (Gumroad)
4. 🔲 **v1.4**: Add app-based routing (Premium)
5. 🔲 **v1.5**: Add kill switch + leak protection (Premium)

---

## Technical Debt / Known Issues

- [ ] Config migration: new default services don't auto-merge into existing user config
- [ ] Helper installation can fail silently on some systems
- [ ] Route verification unreliable (many servers block ICMP)
- [ ] Homebrew Cask not published to a tap yet

---

*Last updated: January 17, 2026*
