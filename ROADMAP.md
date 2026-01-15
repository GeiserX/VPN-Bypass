# VPN Bypass - Product Roadmap

## Current State (v1.0)

### ✅ Implemented Features
- Menu bar app with real-time VPN status
- VPN detection (GlobalProtect, Cisco AnyConnect, OpenVPN, WireGuard)
- Smart Tailscale detection (only VPN when exit node active)
- Domain-based bypass rules
- Pre-configured services (Telegram, YouTube, WhatsApp, Spotify, etc.)
- Route management via system routing table
- Optional `/etc/hosts` management for DNS bypass
- Settings UI with Domains, Services, General, Logs tabs
- Auto-apply routes when VPN connects
- Activity logging

---

## Roadmap

### Phase 1: Polish & Stability (v1.1 - v1.2)
**Timeline: 1-2 months**

| Feature | Description | Tier |
|---------|-------------|------|
| **Improved VPN Detection** | Support more VPN types (Fortinet, Zscaler, Cloudflare WARP) | Free |
| **Network Change Handling** | Better detection when switching networks/WiFi | Free |
| **Notifications** | Alert when VPN connects/disconnects, routes applied | Free |
| **Route Verification** | Verify routes are actually working (ping test) | Free |
| **Import/Export Config** | Backup and restore settings | Free |
| **Launch at Login** | Option to start automatically | Free |

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

```swift
// Example validation
let licenseKey = "XXXX-XXXX-XXXX-XXXX"
let url = "https://api.gumroad.com/v2/licenses/verify"
// POST with product_id and license_key
```

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

### Option 4: RevenueCat (Subscriptions)
- Subscription management
- Cross-platform (if you expand to iOS)
- Analytics built-in
- Pros: Best for subscriptions
- Cons: Monthly fees

### Option 5: Custom (Self-hosted)
- Your own license server
- Full control
- Pros: No fees, full control
- Cons: More work to build/maintain

### Recommended Approach
1. **Start with Gumroad** for quick launch
2. Migrate to **LemonSqueezy** when you need subscriptions
3. Consider **Paddle** for enterprise/international

---

## Implementation: License Gating

### Code Structure
```swift
// LicenseManager.swift
class LicenseManager: ObservableObject {
    @Published var tier: LicenseTier = .free
    @Published var isValidated = false
    
    enum LicenseTier: String, Codable {
        case free
        case premium
        case enterprise
    }
    
    func validateLicense(_ key: String) async -> Bool {
        // Call license API
        // Store in Keychain if valid
        // Return result
    }
    
    func canUseFeature(_ feature: Feature) -> Bool {
        switch feature {
        case .unlimitedDomains:
            return tier != .free
        case .appRouting:
            return tier == .premium || tier == .enterprise
        case .apiAccess:
            return tier == .enterprise
        // etc.
        }
    }
}
```

### Feature Flags
```swift
enum Feature {
    case unlimitedDomains
    case unlimitedServices
    case appRouting
    case inverseMode
    case killSwitch
    case leakProtection
    case profiles
    case customDNS
    case scheduledRules
    case apiAccess
    case mdmSupport
}
```

### UI Gating Example
```swift
Button("Add Domain") {
    if routeManager.config.domains.count >= 5 && 
       licenseManager.tier == .free {
        showUpgradePrompt = true
    } else {
        addDomain()
    }
}
```

---

## Competitive Analysis

| App | Platform | Key Features | Pricing |
|-----|----------|--------------|---------|
| **Surfshark Bypasser** | macOS | Per-app/website split tunneling | Part of Surfshark subscription |
| **ProtonVPN** | macOS | Split tunneling, kill switch, custom DNS | Free tier + $4.99/mo |
| **VPN Peek** | macOS | Status monitoring, leak detection | $3.99 one-time |
| **MacInfo** | macOS | VPN status, IP display, diagnostics | Free |
| **Tunnelblick** | macOS | OpenVPN client, split routing | Free (open source) |
| **vpn-route-manager** | macOS | Domain/service routing | Free (open source) |

### Our Differentiators
1. **Smart VPN Detection** - Correctly identifies corporate VPNs vs Tailscale mesh
2. **Pre-configured Services** - One-click enable for popular services
3. **Beautiful UI** - Modern SwiftUI interface
4. **No VPN Required** - Works with ANY VPN, not tied to a provider
5. **Privacy-focused** - No analytics, no cloud dependency

---

## Success Metrics

### Free Tier
- Downloads/installs
- Daily active users
- Feature usage (which services enabled)
- Retention (7-day, 30-day)

### Premium Conversion
- Conversion rate from free to premium
- Revenue per user
- Churn rate (for subscriptions)
- Support ticket volume

### Enterprise
- Number of enterprise customers
- Seats per organization
- Contract value
- Renewal rate

---

## Next Steps

1. **v1.1**: Add notifications, improve stability
2. **v1.2**: Add import/export, launch at login
3. **v1.3**: Implement license system (Gumroad)
4. **v1.4**: Add app-based routing (Premium)
5. **v1.5**: Add kill switch (Premium)

---

*Last updated: January 2026*
