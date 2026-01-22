# Changelog

All notable changes to VPN Bypass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.5] - 2026-01-22

### Added
- **DoH Fallback** - Uses DNS over HTTPS (Cloudflare, Google) when regular DNS fails, bypassing VPN DNS hijacking
- **getaddrinfo Timeout** - 3 second timeout prevents hanging on unresponsive system resolver

## [1.6.4] - 2026-01-22

### Added
- **DNS Retry Logic** - Retries DNS resolution once (300ms delay) before giving up
- **System Resolver Fallback** - Uses macOS getaddrinfo() as last resort when dig fails
- **Background Hosts Update** - Hosts file now updated after successful background DNS refresh

## [1.6.3] - 2026-01-22

### Fixed
- **Light Mode Dropdown Visibility** - Background colors now visible in both light and dark modes
- **Hosts File Fallback** - Uses disk cache for hosts file entries when DNS fails at startup

## [1.6.2] - 2026-01-21

### Fixed
- **Remove Stale IPs on Refresh** - Auto DNS refresh now removes IPs that are no longer resolved (was only adding, never removing)

## [1.6.1] - 2026-01-21

### Fixed
- **Deduplicate Routes** - Multiple domains resolving to the same IP no longer create duplicate routes

## [1.6.0] - 2026-01-21

### Added
- **Instant Startup** - If DNS cache exists, applies routes immediately (~2-3s) then refreshes DNS in background
- **DNS Disk Cache** - Resolved IPs are saved to disk and used as fallback when DNS fails
- **Faster Service Toggle** - Enabling a service now resolves all domains in parallel + batch route addition

### Changed
- **Smarter DNS Timeouts** - Local DNS (192.168.x.x, 10.x.x.x): 1s timeout; External DNS: 1.5s timeout
- DNS cache stored at `~/Library/Application Support/VPNBypass/dns-cache.json`

## [1.5.5] - 2026-01-21

### Fixed
- Removed debug logging code from 1.5.4

## [1.5.3] - 2026-01-21

### Fixed
- **Prevent Double Route Application** - Added guard to skip duplicate route application within 5 seconds
- **Fixed Invalid Default Domains** - Removed non-resolving domains: `twimg.com` → `pbs.twimg.com`, `cdninstagram.com` → `scontent.cdninstagram.com`, `api.signal.org` → `chat.signal.org`

### Changed
- **Faster DNS Timeouts** - Reduced DNS timeout from 4s to 2s (1s dig timeout)
- **Larger Batch Size** - Increased from 50 to 100 domains per parallel batch
- **Faster DoH/DoT** - Reduced timeout from 5s to 3s

## [1.5.2] - 2026-01-21

### Fixed
- **True Parallel DNS** - Fixed thread blocking in DNS resolution (was using sync calls that blocked cooperative threads)
- **Auto-Update Helper** - App now detects helper version mismatch and auto-updates (was only installing on first launch)

### Changed
- DNS resolution now uses `DispatchQueue.global()` for true GCD parallelism

## [1.5.1] - 2026-01-21

### Fixed
- **Massive Performance Improvement** - Route application reduced from 3-5 minutes to ~10 seconds
- **True Parallel DNS Resolution** - Fixed `@MainActor` serialization that was blocking parallel execution
- **Batch Route Operations** - Routes now added/removed via single XPC call instead of 300+ individual calls
- **DNS Cache for Hosts File** - Eliminated duplicate DNS resolution (was resolving all domains twice)
- **Increased DNS Batch Size** - From 5 to 50 domains per parallel batch

### Changed
- Helper version bumped to 1.2.0 (will auto-reinstall on first launch)
- DNS resolution functions now `nonisolated static` for true concurrency

## [1.3.4] - 2026-01-19

### Fixed
- **DNS Resolution Fallback** - Now falls back to system DNS if detected DNS fails
- **Reduced Log Spam** - Individual resolution failures no longer spam logs; shows summary instead
- **Faster DNS Queries** - Added timeout flags to dig (+time=2, +tries=1)

## [1.3.3] - 2026-01-19

### Fixed
- **App Icon** - Official logo now shows in Finder, Launchpad, and Dock

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
