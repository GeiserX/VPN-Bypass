# Installation

## Homebrew (Recommended)

```bash
# Add the tap (first time only)
brew tap geiserx/vpn-bypass

# Trust the tap (first time only, required on Homebrew 6+)
brew trust --cask geiserx/vpn-bypass/vpn-bypass

# Install VPN Bypass
brew install --cask vpn-bypass
```

The **tap is the canonical install path** — it always tracks the latest release and auto-updates with `brew upgrade`. On Homebrew 6+, trust the tap first (as shown above) or the install will be blocked.

> **Note:** Don't `brew install --cask` the raw `Casks/vpn-bypass.rb` in this repo — that in-repo cask is a frozen snapshot and will install an old build. Always use the tap above.

## Manual Download

Download the latest `.dmg` from [Releases](https://github.com/GeiserX/VPN-Bypass/releases), open it, and drag **VPN Bypass** to your Applications folder.

## Build from Source

```bash
# Clone the repository
git clone https://github.com/GeiserX/VPN-Bypass.git
cd VPN-Bypass

# Build and create release DMG
make release

# Or just build and run
make run
```

## Xcode

Open `Package.swift` in Xcode and run the project.


## Requirements

- macOS 13.0 (Ventura) or later
- Admin privileges (for route management and hosts file)

## Permissions

The app requires:
- **Network access**: To detect VPN connections and resolve domains
- **Admin privileges**: To add routes and modify `/etc/hosts` (prompted when needed)
- **Notifications**: Optional, for VPN status alerts (prompted on first launch)
