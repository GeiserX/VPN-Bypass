# Getting started

## Homebrew (Recommended)

```bash
# Add the tap (first time only)
brew tap geiserx/vpn-bypass

# Trust the tap (first time only, required on Homebrew 6+)
brew trust --cask geiserx/vpn-bypass/vpn-bypass

# Install VPN Bypass
brew install --cask vpn-bypass
```

The tap is the canonical install path: it tracks the latest release and updates with `brew upgrade`. On Homebrew 6+, trust the tap first (as shown above) or the install will be blocked.

Do not install the raw `Casks/vpn-bypass.rb` from this repository; it is a frozen snapshot and installs an old build.

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

## First run

1. Open VPN Bypass from Applications. It lives in the menu bar; there is no Dock icon.
2. macOS asks for an administrator password once. That installs the root helper that edits the routing table. On macOS 13 and later it may also ask you to allow VPN Bypass under System Settings > General > Login Items; the app says so in its dropdown when that is the case.
3. Connect your VPN. The dropdown reads VPN Connected and names the client it found.

A fresh install routes nothing: the pill in the dropdown reads NO ROUTES and a line says nothing is configured yet.

![The dropdown right after install: VPN Connected, the pill reads NO ROUTES, and a hint says nothing is configured yet](images/screenshots/first-run.png){ width="340" }

Turn on a service in Settings > Services, or type a domain into the dropdown's Add Domain field. It worked when:

- the pill reads ON;
- the menu bar mark shows its arrow head (it is two plain lines and a bar while nothing is routed);
- the service or domain appears in the dropdown under Active Services or Active Routes.

If the pill reads NOT ENFORCING, the helper is not running; Settings > General shows its state and a Reinstall button. If macOS says the app is damaged, see [Troubleshooting](troubleshooting.md#app-wont-open-damaged-error-macos-gatekeeper).

## Requirements

- macOS 13.0 (Ventura) or later
- Admin privileges (for route management and hosts file)

## Permissions

The app requires:
- **Network access**: To detect VPN connections and resolve domains
- **Admin privileges**: To add routes and modify `/etc/hosts` (prompted when needed)
- **Notifications**: Optional, for VPN status alerts (prompted on first launch)
