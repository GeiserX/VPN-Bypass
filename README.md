# VPN Bypass

A macOS menu bar app that automatically routes specific domains and services around your VPN, ensuring they use your regular internet connection.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Why?

Corporate VPNs often route all traffic through the tunnel, which can cause issues:

- **Performance**: Streaming and messaging apps become slow or buffer constantly
- **Broken features**: Chromecast, AirPlay, and location-based features fail
- **Unnecessary load**: Non-business traffic clogs the VPN tunnel
- **Privacy**: Personal services don't need to go through corporate infrastructure

VPN Bypass intelligently routes selected services directly to the internet while keeping business traffic secure through VPN.

## Features

- 🎯 **Menu bar app** - Quick access to status and controls
- 🔧 **Pre-configured services** - Telegram, YouTube, WhatsApp, Spotify, Tailscale, and more
- 🌐 **Custom domains** - Add any domain you want to bypass
- 🔄 **Auto-apply** - Routes are applied automatically when VPN connects
- 📋 **Hosts file management** - Optional DNS bypass via `/etc/hosts`
- 🪵 **Activity logs** - See what's happening in real-time

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/GeiserX/vpn-macos-bypass.git
cd vpn-macos-bypass

# Build
swift build -c release

# Run
.build/release/VPNBypass
```

### Xcode

Open `Package.swift` in Xcode and run the project.

## Usage

### Menu Bar

Click the shield icon in the menu bar to:
- See VPN connection status
- View active bypass routes
- Quick-add domains to bypass
- Refresh or clear routes

### Settings

Click the gear icon to access settings:

**Domains Tab**
- Add custom domains to bypass
- Enable/disable individual domains
- See resolved IPs

**Services Tab**
- Toggle pre-configured services
- Each service includes known domains and IP ranges

**General Tab**
- Auto-apply routes when VPN connects
- Manage `/etc/hosts` entries

**Logs Tab**
- View recent activity
- Debug connection issues

## Pre-configured Services

| Service | Domains | Status |
|---------|---------|--------|
| Telegram | telegram.org, t.me, etc. | Enabled by default |
| Tailscale | login.tailscale.com, etc. | Enabled by default |
| YouTube | youtube.com, googlevideo.com, etc. | Disabled |
| WhatsApp | whatsapp.com, web.whatsapp.com | Disabled |
| Spotify | spotify.com, scdn.co | Disabled |
| Slack | slack.com, slack-edge.com | Disabled |
| Discord | discord.com, discordcdn.com | Disabled |
| Twitch | twitch.tv, twitchcdn.net | Disabled |

## How It Works

1. **VPN Detection**: Monitors network interfaces for VPN tunnels (utun, ipsec, ppp, gpd)
2. **Gateway Detection**: Identifies your local gateway (Wi-Fi/Ethernet router)
3. **Route Management**: Adds host routes to send specific traffic through local gateway instead of VPN
4. **DNS Bypass**: Optionally adds entries to `/etc/hosts` to bypass VPN DNS

## Requirements

- macOS 13.0 (Ventura) or later
- Admin privileges (for route management and hosts file)

## Permissions

The app requires:
- **Network access**: To detect VPN connections and resolve domains
- **Admin privileges**: To add routes and modify `/etc/hosts` (prompted when needed)

## Troubleshooting

### Routes not being applied

1. Check if VPN is actually connected (look for utun interface)
2. Verify local gateway is detected in Settings → General
3. Check Logs tab for errors

### Hosts file not updating

The app will prompt for admin password when modifying `/etc/hosts`. If you deny, disable this feature in Settings → General.

### DNS still going through VPN

Some VPNs force DNS through the tunnel. The hosts file entries help bypass this, but you may also need to:
- Disable "Route all DNS through VPN" in your VPN client
- Use a local DNS resolver

## Acknowledgments

Inspired by:
- [vpn-route-manager](https://github.com/btriapitsyn/vpn-route-manager) - Go-based VPN route manager
- Original shell script implementation in `vpn-bypass`

## License

MIT License - see [LICENSE](LICENSE) for details.
