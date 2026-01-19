# Changelog

All notable changes to VPN Bypass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.2] - 2026-01-19

### Fixed
- **Parallel DNS Resolution** - Route setup now resolves domains in parallel (much faster)
- **No More "Setting Up" Stuck** - VPN connection no longer hangs on route application
- **Route Count Display** - Menu bar now shows route count reliably after VPN connects

## [1.3.1] - 2026-01-18

### Fixed
- **Settings First Click** - Settings window now opens reliably on first gear click
- **Pre-warm Controller** - SettingsWindowController initialized at launch for instant response

## [1.3.0] - 2026-01-18

### Added
- **Silent Notifications** - Option to disable notification sounds
- **Service/Domain Notifications** - Notify when services or domains are toggled (when Routes enabled)
- **DNS Refresh Notifications** - Notify when DNS refresh completes with route updates

### Changed
- **Route Notifications OFF by Default** - Less noisy for most users; enable in Settings for verbose feedback
- **Simplified Notification UI** - Added "Silent" toggle and helper text explaining Routes scope

## [1.2.1] - 2026-01-18

### Added
- **AGENTS.md** - AI agent instructions for development assistance

### Changed
- **Homebrew Auto-Update** - Release workflow now pushes directly to homebrew tap (like LynxPrompt)
- **CI Improvements** - Added HOMEBREW_TAP_TOKEN for automated cask updates

## [1.2.0] - 2026-01-17

### Added
- **Auto DNS Refresh** - Periodically re-resolves domains and updates routes (default: 1 hour)
- **Route Health Dashboard** - View active routes, enabled services, DNS server info in Logs tab
- **Privileged Helper** - One-time admin prompt instead of repeated sudo requests
- **Info Tab** - Author info, support links, and license details in Settings
- **GitHub Community Files** - Issue templates, funding links, contributing guidelines
- **Homebrew Cask** - Install via `brew install --cask vpn-bypass`

### Changed
- **Async Process Execution** - All shell commands now run on background threads (no more UI lag)
- **Incremental Route Updates** - Toggling services/domains only adds/removes affected routes
- **Smarter DNS Resolution** - Respects user's pre-VPN DNS server when available
- **Improved Branding** - Custom logo, "VPN" in blue / "Bypass" in silver throughout app

### Fixed
- UI freezing when applying routes or detecting VPN
- Settings panel now appears above menu dropdown
- Route count updates automatically on startup without manual refresh
- Notifications now appear in System Settings (when app is properly signed)
- Domain removal now actually removes kernel routes

## [1.1.0] - 2026-01-14

### Added
- **Extended VPN Detection** - Fortinet FortiClient, Zscaler, Cloudflare WARP, Pulse Secure, Palo Alto
- **Network Monitoring** - Improved detection when switching WiFi networks
- **Notifications** - Alerts when VPN connects/disconnects and routes are applied
- **Route Verification** - Ping tests to verify routes are actually working
- **Import/Export Config** - Backup and restore your domains and services
- **Launch at Login** - Option to start automatically when you log in

### Changed
- Better VPN interface detection logic
- Improved Tailscale exit node detection

### Fixed
- False positive VPN detection for Tailscale mesh networking
- Gateway detection on some network configurations

## [1.0.0] - 2026-01-10

### Added
- Initial release
- Menu bar app with VPN status and controls
- Pre-configured services: Telegram, YouTube, WhatsApp, Spotify, Tailscale, Slack, Discord, Twitch
- Custom domain support
- Auto-apply routes when VPN connects
- Hosts file management for DNS bypass
- Activity logs
- Settings UI with Domains, Services, General, and Logs tabs
