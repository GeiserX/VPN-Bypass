# Changelog

All notable changes to VPN Bypass will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.7.0] - 2026-05-04

### Changed
- **Library extraction** — Extracted `VPNBypassCore` as a separate SPM library target, enabling unit testing of business logic without launching the full app

### Added
- **552 unit tests** across 10 new test files covering RouteManager config mutations, domain cleaning, IP/CIDR validation, Codable roundtrips, HelperState, notification preferences, Theme constants, and more
- **Codecov integration** — Coverage tracking with exclusions for system-dependent code (XPC, VPN detection, SwiftUI views)

## [2.6.2] - 2026-05-03

### Fixed
- **Spurious VPN notifications** — Suppress transient VPN interface flaps that caused repeated "VPN Connected" notifications while VPN was still active. Now rechecks after 1.5s before committing to a disconnect state.

## [2.6.1] - 2026-05-03

### Removed
- **Wildcard domain support** — Removed `*.example.com` syntax. macOS routing is IP-based and `/etc/hosts` does not support wildcards, so the feature only resolved the base domain and could not actually route subdomains with different IPs. This was misleading.

### Changed
- **Simplified `DomainEntry`** — Removed `resolvableDomain` computed property (no longer needed without wildcards)

## [2.6.0] - 2026-05-03

### Added
- **Centralized theme system** — New `Theme.swift` with semantic colors, WCAG AA-compliant contrast ratios, and consolidated brand identity (`Theme.Brand`)
- **Menu bar state icons** — Three distinct template images (default/active/error) for at-a-glance status
- **Modern app icon** — Redesigned shield icon with gradient and arrow motif
- **VoiceOver accessibility** — Menu bar icon announces current state (active routes count, helper errors, etc.)
- **Reduced motion support** — Pulse animation respects `accessibilityReduceMotion` system preference

### Fixed
- **Retry DNS tracking** — `retryFailedDomain` now passes the `source:` parameter for correct route tracking
- **Reactive helper state** — Menu bar icon updates immediately when helper state changes (was reading a static reference)
- **DNS input validation** — `resolveWithDNSParallel` now rejects whitespace, semicolons, and shell metacharacters in DNS server strings
- **Theme consistency** — Replaced remaining hardcoded `Color.white.opacity()` values with semantic theme tokens
- **WCAG AA compliance** — `textDisabled` color bumped from 3.95:1 to 4.6:1 contrast ratio

### Changed
- **250+ hardcoded colors replaced** with semantic `Theme.*` tokens across all views
- **`BrandColors` consolidated** into `Theme.Brand` nested enum (single source of truth)

## [2.4.2] - 2026-04-10

### Fixed
- **VPN Gateway Race Condition** - VPN Only mode used the local router as VPN gateway when VPN routing table wasn't fully ready at detection time. Now skips gateway IPs that match the local gateway and re-detects gateway when switching to VPN Only mode ([#26](https://github.com/GeiserX/VPN-Bypass/issues/26))

## [2.4.1] - 2026-04-10

### Fixed
- **Multi-VPN Interface Selection** - VPN Only mode now prefers the `interface:` reported by `route -n get default` instead of the first VPN-looking interface from `ifconfig` when no IP gateway is available, fixing wrong-tunnel selection in multi-VPN setups ([#27](https://github.com/GeiserX/VPN-Bypass/pull/27))
- **Safer Route Interface Fallback** - Route-derived interface fallback is now accepted only when it still looks like a VPN/tunnel device, preserving the existing ifconfig fallback for odd default-route outputs

## [2.4.0] - 2026-04-10

### Added
- **Cisco Secure Client Support** - VPN Only mode now works with Cisco Secure Client (AnyConnect) which routes via interface link instead of an IP gateway. The helper supports interface-based routing (`-interface utun`) when no gateway IP is available ([#26](https://github.com/GeiserX/VPN-Bypass/issues/26))
- **Improved Cisco Detection** - Added `secureclient` process name matching for Cisco Secure Client 5.x identification

### Changed
- **Helper v1.4.0** - Updated privileged helper to support interface-based route addition. Existing users will be prompted once to update the helper on first launch

## [2.3.3] - 2026-04-08

### Added
- **Login Item Detection** - Detects when users disable VPN Bypass in System Settings → Login Items and shows a helpful error message instead of re-prompting for admin password on every boot ([#25](https://github.com/GeiserX/VPN-Bypass/issues/25))

## [2.3.2] - 2026-04-08

### Fixed
- **Tab Label Wrapping** - Spanish/French tab labels no longer wrap mid-word; compact sizing applied only for non-English languages while keeping original size for English

## [2.3.1] - 2026-04-08

### Changed
- **Author Subtitle** - Updated author credit in Info tab

## [2.3.0] - 2026-04-08

### Added
- **Localization** - Full English, Spanish, and French translations for all UI strings including settings, menu bar, helper status messages, and error states ([#24](https://github.com/GeiserX/VPN-Bypass/pull/24))

## [2.2.0] - 2026-04-06

### Added
- **Intel Mac Support** - App and helper are now built as universal binaries (arm64 + x86_64), fixing launch failures on Intel Macs ([#22](https://github.com/GeiserX/VPN-Bypass/issues/22))

### Fixed
- **Settings Window Minimize** - Settings window now shows a Dock icon while open, so the minimize button works correctly instead of sending the window to an invisible Dock section

## [2.1.2] - 2026-03-31

### Fixed
- **Menu Bar Icon Redesign** - Replaced complex 13-point arrow (unreadable at 18px) with a clean bold right-arrow (7 points). Re-rendered from SVG with proper alpha transparency
- **Dropdown/Settings Logo Artifacts** - Replaced raw 650x514 PNG (artifact-heavy at small sizes) with `NSApp.applicationIconImage` which macOS renders optimized for each display size

## [2.1.1] - 2026-03-31

### Fixed
- **Menu Bar Black Square** - Converted menu bar icons from 16-bit to 8-bit grayscale+alpha; CoreGraphics `mask_create` rejects 16-bit images as template masks
- **Helper Update Not Taking Effect** - `SMAppService.register()` silently succeeds without replacing the on-disk binary; helper updates now always use the legacy AppleScript path which does the actual file copy and `launchctl` reload

## [2.1.0] - 2026-03-31

### Changed
- **Native Settings Window** - Replaced persistent `NSPanel` with a standard `NSWindow` featuring minimize, close, and full traffic light controls
- **Official Logo Everywhere** - Menu bar uses a template icon (`menubar-icon.png`) for proper dark/light mode, dropdown header uses the official 3D logo instead of SF Symbols
- **Larger Tab Buttons** - Settings tab items enlarged to 13pt with rounded-rectangle styling for better usability
- **Git-Derived Version** - App version is now stamped from the latest git tag at build time via `PlistBuddy`, eliminating hardcoded version strings

### Fixed
- **Helper Startup Race** - App no longer hangs at "Setting Up" when the privileged helper is outdated. A new `ensureHelperReady()` preflight verifies the helper is installed, running, and at the expected version before any route application begins
- **XPC Timeout Protection** - All XPC calls now use a hard wall-clock deadline (`OnceGate` + `DispatchQueue.asyncAfter`) instead of cooperative task cancellation, preventing indefinite hangs when the helper is unresponsive
- **Helper State Machine** - New `HelperState` enum (`missing`, `checking`, `installing`, `outdated`, `ready`, `failed`) with reactive UI throughout the app
- **Auto-Update on Version Mismatch** - Helper is automatically reinstalled when version mismatch is detected, with XPC connection reset and post-update verification
- **Helperless Fallback Removal** - All direct `/sbin/route` and AppleScript fallback paths removed; every route-mutating operation now requires the privileged helper, eliminating silent failures and false state
- **Settings Recovery** - Install/Update/Retry button in Settings runs full `ensureHelperReady()` preflight and automatically applies routes + restarts DNS timer if VPN is connected
- **Window Minimize/Reopen** - Minimized settings window is properly restored instead of creating a new instance
- **Strict Concurrency** - `OnceGate` marked `@unchecked Sendable` with `T: Sendable` constraint, eliminating all strict-concurrency warnings from the XPC deadline infrastructure

## [2.0.0] - 2026-03-30

### Added
- **VPN Only Mode (Inverse Routing)** - New dual routing mode: "Bypass" (default, existing behavior) and "VPN Only" where only listed domains use VPN while everything else bypasses it. Uses 0.0.0.0/1 + 128.0.0.0/1 catch-all routes through the local gateway with domain-specific routes through the VPN gateway
- **Routing Mode Selector** - Radio-button mode selector in both the menu bar dropdown and the Settings Domains tab to switch between Bypass and VPN Only modes
- **Separate Domain Lists** - Each routing mode maintains its own domain list: bypass domains for Bypass mode, VPN-only domains for VPN Only mode
- **Custom Services** - Create your own service entries with a name, multiple domains, and optional IP ranges. Custom services are shown with a purple "Custom" badge, can be edited/deleted, and persist across reboots
- **Custom Service Editor** - Full sheet editor for creating and editing custom services with add/remove buttons for domains and IP ranges
- **Multi-Source Route Ownership** - Routes now track their origin (service name, domain, or CIDR) via `allSourceEntries`, preventing cross-source conflicts during incremental updates

### Changed
- **Services Tab** - Shows a disabled banner in VPN Only mode (services only apply in Bypass mode). Added "+ Create Custom Service" button for user-defined services
- **VPN Gateway Detection** - App now detects both local and VPN gateways simultaneously for inverse routing support
- **Route Operation Serialization** - Complete rewrite of concurrency model: exclusive `acquireRouteOperation`/`releaseRouteOperation` gate prevents concurrent route modifications, epoch-based preemption detection (`routeEpoch`) ensures teardown safely cancels in-flight operations, and gate-free teardown guarantees disconnect/quit always proceeds without deadlock
- **Kernel-Authoritative Route Model** - Route removal now reads kernel state as source of truth instead of relying solely on the in-memory model, preventing model/kernel divergence
- **Delete-Before-Add Pattern** - Route application now deletes existing entries before adding, eliminating "route already exists" errors during re-application
- **Background DNS Refresh** - Deduplicates kernel operations by destination, uses source-aggregate diffs to prevent false-positive change counts

### Fixed
- **Shell Injection in Route Commands** - Sanitized all inputs to shell route commands
- **XPC Authorization Hardening** - Strengthened privileged helper authorization checks
- **In-Flight Apply Survives Teardown** - Gate-free teardown could clear routes while a concurrent apply was running, which would then overwrite `activeRoutes` with stale data. Epoch counter now lets in-flight operations detect preemption and abort before committing
- **Interface/Tailscale Reroute Race** - VPN interface switch and Tailscale reroute now hold the operation gate across the full remove-then-reapply sequence instead of releasing between operations
- **Mode Switch Safety** - Switching routing modes now holds the gate across the full teardown-and-rebuild cycle with proper precondition checks
- **Stale Route Cleanup** - Two-population cleanup distinguishes truly orphaned routes (re-attach on failure) from add-failed routes (don't re-attach), preventing phantom route accumulation
- **Hosts File Sync on All Mutations** - Adding, toggling, or removing domains now immediately syncs `/etc/hosts` instead of waiting for periodic refresh
- **Multi-IP Hosts Lookup** - Hosts file entries now correctly handle domains that resolve to multiple IPs
- **Scoped Orphan Host Cleanup** - Orphan detection uses a saved domain list, preventing removal of hosts entries that are still needed
- **DNS Cache Persistence for Custom Services** - Custom service DNS resolutions are now cached to disk for instant startup
- **Stale DNS Cache on Import** - Importing a configuration now cleans stale DNS cache entries from removed domains
- **Batch Failure Tracking** - Route batch operations now report per-route success/failure instead of all-or-nothing, with accurate counts in notifications
- **Disconnect Notification Accuracy** - VPN disconnect notification now reports the correct count of routes that couldn't be removed
- **Config Import Reconciliation** - Importing a config now properly reconciles running routes with the new configuration
- **Quit Cleanup** - App quit now properly removes all routes before exiting
- **Bulk Toggle Epoch Safety** - "Enable All"/"Disable All" in domains tab now checks for preemption between each domain operation

## [1.9.2] - 2026-03-29

### Fixed
- **Zscaler Detection in CGNAT Range** - Non-Tailscale CGNAT IPs (100.64.x.x) on VPN interfaces are now accepted without requiring a process-name hint, fixing detection when Zscaler runs newer system extensions like `TRPTunnel` that don't match legacy process patterns (Closes #18)

### Improved
- **Zscaler Process Detection** - Added `TRPTunnel` (transparent proxy system extension) and `UPMServiceController` to recognized Zscaler process names for accurate VPN type identification
- **VPN Detection Logging** - Process hint type is now logged during detection, making it easier to diagnose unrecognized VPN clients

## [1.9.1] - 2026-03-05

Thanks to [@karle0wne](https://github.com/karle0wne) for contributing this release (#16).

### Fixed
- **Tailscale Profile Switch Detection** - Routes are now automatically refreshed when switching Tailscale accounts/profiles while the VPN stays on the same `utun` interface. Previously, stale bypass routes from the old profile would persist until manual refresh (#16)
- **Info Page Version Display** - The About/Info page header showed a hardcoded version instead of reading from the bundle. Now uses `CFBundleShortVersionString` like the rest of the app

### Improved
- **Tailscale CLI Performance** - All Tailscale status queries now use `--self --peers=false`, fetching only the local node's data instead of the entire peer list. Significantly reduces JSON payload and parsing time on large tailnets
- **DRY Tailscale JSON Reading** - Deduplicated Tailscale CLI invocations into a single `readTailscaleStatusJSON()` helper shared across exit node detection, IP checking, and profile fingerprinting

## [1.9.0] - 2026-02-28

### Added
- **Auto-Merge Built-In Service Updates** - App updates now automatically apply new domains, IP ranges, and service names from the latest version while preserving your enabled/disabled preferences. No more stale domain lists after upgrading

### Improved
- **OpenAI / ChatGPT Service** - Added all relevant OpenAI and ChatGPT domains including core properties, auth, CDN, Azure/Cloudflare infrastructure, LiveKit voice, anti-bot, and analytics endpoints

### Fixed
- **Version Display** - App now reads version from the bundle at runtime instead of a hardcoded string, ensuring the displayed version always matches the release (#15)

## [1.8.1] - 2026-02-25

### Fixed
- **Stale Gateway on Domain Addition** - Adding/toggling domains now re-detects the local gateway if stale, instead of silently failing when VPN switches interfaces
- **VPN Interface Switch Not Handled** - Routes are now automatically re-applied when VPN hops interfaces (e.g., utun4 → utun5) while staying connected
- **Network Monitor Missing VPN Changes** - NWPathMonitor now tracks individual interface names, catching VPN interface switches that type-only comparison missed

### Improved
- **No More Silent Failures** - All gateway-dependent actions now log explicit errors when no gateway is available, instead of silently skipping route application
- **Fresh Gateway in All User Actions** - `addDomain`, `toggleDomain`, `toggleService`, `setAllDomainsEnabled`, `setAllServicesEnabled`, and DNS retry all use fresh gateway detection

## [1.8.0] - 2026-02-25

### Added
- **Parallel DNS Resolution** - Dig and DoH now race simultaneously instead of running sequentially. When VPN blocks UDP DNS, DoH wins in ~2s instead of waiting 8+ seconds for dig timeouts first
- **Auto-Retry on DNS Failure** - When adding a domain fails DNS resolution, a 15-second auto-retry is scheduled with cancellation support
- **Immediate Hosts File Update** - Adding or toggling a domain now updates `/etc/hosts` immediately instead of waiting for the periodic refresh

### Fixed
- **Domain Addition Not Bypassing VPN** - Adding a custom domain while connected to VPN now works instantly: DNS cache, disk cache, and hosts file are all populated immediately on success
- **Stale Gateway in Retries** - DNS retry now reads the current gateway instead of using a potentially stale captured value
- **Bulk Enable Disk Thrashing** - "Enable All" no longer writes the DNS cache to disk once per domain; saves once at the end

### Improved
- **DNS Trust Hierarchy** - Trusted dig-based resolvers get a 200ms head start over DoH, preserving CDN locality when local DNS works while still falling back fast on VPN
- **Tracked Retry Tasks** - Retry tasks are now tracked and cancelled on domain removal, VPN disconnect, or route cleanup
- **Consistent State Management** - Removed redundant `MainActor.run` wrappers inside already-MainActor tasks; `isApplyingRoutes` properly set during retries

## [1.7.1] - 2026-02-24

### Fixed
- **Zscaler Detection** - Zscaler (and Cloudflare WARP) use CGNAT IPs (`100.64.x.x`) which were incorrectly treated as Tailscale-only, causing `valid=false` rejection. Now trusts the process-detection hint to distinguish Zscaler/WARP from Tailscale in the shared CGNAT range.

## [1.7.0] - 2026-02-22

### Added
- **Check Point VPN Detection** - Detects Check Point Endpoint Security VPN via process signatures (`Endpoint_Security_VPN`, `TracSrvWrapper`, `cpdaApp`, `cpefrd`)

### Fixed
- **Homebrew Tap Command** - Fixed `brew tap geiserx/tap` (repo doesn't exist) to `brew tap geiserx/vpn-bypass`
- **Stale Repository URLs** - Updated all remaining `vpn-macos-bypass` references to `VPN-Bypass` across README, issue templates, cask, and settings

## [1.6.11] - 2026-02-05

### Improved
- **Better URL Cleaning** - Enhanced domain input parsing when adding custom domains
  - Strips any protocol scheme (http, https, ssh, ftp, and any other `scheme://` format)
  - Removes port numbers (e.g., `:443`, `:8080`)
  - Removes authentication info (e.g., `user:pass@`)
  - Removes paths and query strings
  - Now you can paste full URLs and the domain will be extracted correctly

## [1.6.10] - 2026-01-29

### Fixed
- **VPN Detection Reliability** - Rewrote interface detection with two-pass approach
  - Collects ALL interfaces first, then validates (more robust than single-pass)
  - Better debug logging shows exactly which VPN candidates were found
  - Ensures hasUpFlag is correctly tracked per-interface

## [1.6.9] - 2026-01-28

### Fixed
- **Critical: GCD Thread Pool Exhaustion** - Fixed ifconfig timeouts after extended runtime
  - Replaced nested GCD dispatch + semaphore pattern that caused thread starvation
  - Uses dedicated process queue to isolate process execution
  - Uses polling-based timeout instead of nested dispatch
  - Prevents the "ifconfig command failed/timed out" issue that blocked VPN detection

## [1.6.8] - 2026-01-26

### Added
- **Watchdog Timer** - Restarts network monitor every 12 hours to prevent stale state during long uptimes
- **Uptime Tracking** - Logs app uptime and VPN status during watchdog checks

## [1.6.7] - 2026-01-26

### Fixed
- **Improved VPN Detection Logging** - Better diagnostic logging when VPN detection fails

## [1.6.6] - 2026-01-23

### Changed
- **Rebranded to VPN Bypass** - Release names and DMG files now use "VPN Bypass" / "VPN-Bypass" naming
- **Updated GitHub URLs** - All links now point to the renamed repository

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
