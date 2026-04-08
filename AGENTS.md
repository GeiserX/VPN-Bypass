# VPN Bypass - AI Agent Instructions

## Project Overview

**Description**: macOS menu bar app to bypass VPN for specific domains and services

**Visibility**: Public repository
**Development OS**: macOS

### Repository
- **Platform**: GitHub

### Reference Materials
- **Example Repository**: https://github.com/GeiserX/lynxprompt

## Technology Stack

### Languages
- swift

### AI Technology Selection
For technologies beyond those listed, analyze the codebase and suggest appropriate solutions.

## Development Guidelines

### Communication Style
- Be concise and direct
- Developer context: devops
- Skill level: Senior

### Workflow Rules
- Always install and test via Homebrew (never swift build for testing)
- Check logs when build or commit finishes
- Match the codebase's existing style and patterns
- Confirm before making significant changes

### Testing Changes
After releasing, wait for workflow then install via Homebrew:
```bash
cd /opt/homebrew/Library/Taps/geiserx/homebrew-vpn-bypass && git pull
pkill -9 "VPN Bypass" 2>/dev/null || true
brew reinstall --cask vpn-bypass
open "/Applications/VPN Bypass.app"
```

### Important Files to Read First
Before making changes, read these files to understand the project:
- README.md
- CHANGELOG.md

### CI/CD & Infrastructure
- **CI/CD Platform**: GitHub Actions

### Releasing New Versions

1. Run `./scripts/bump-version.sh <version>` — updates Info.plist, README.md badge, and Casks/
2. Update `docs/CHANGELOG.md` with release notes
3. Commit: `git add -A && git commit -m "chore: release v<version>"`
4. Tag and push: `git tag v<version> && git push && git push origin v<version>`

CI (`.github/workflows/release.yml`) does the rest automatically:
- Builds universal DMG (arm64 + x86_64)
- Creates GitHub Release with the DMG
- Updates the Homebrew cask in `homebrew-vpn-bypass` repo

**Do NOT manually** create GitHub releases, upload DMGs, or update the Homebrew cask — CI will overwrite them.

After CI completes: `brew update && brew upgrade --cask vpn-bypass` to install locally.

**Version architecture**: The app reads its version from `CFBundleShortVersionString` at runtime (not hardcoded). CI stamps it from the git tag. `bump-version.sh` keeps `Info.plist` and `README.md` badge in sync for local builds.

## Best Practices

- **Write clean code**: Prioritize readability and maintainability
- **Handle errors properly**: Don't ignore errors, handle them appropriately
- **Consider security**: Review code for potential security vulnerabilities
- **Conventional commits**: Use conventional commit messages (feat:, fix:, docs:, chore:, refactor:, test:, style:)
- **Semantic versioning**: Follow semver (MAJOR.MINOR.PATCH) for version numbers

## Learned Patterns

- **Never skip `bump-version.sh`** before tagging a release. Forgetting it caused version desync in v1.8.2–v1.9.0 (#15).
- **Version display is dynamic** — do NOT hardcode version strings in Swift code. The app reads from the bundle's `CFBundleShortVersionString` at runtime.
- **Always test via Homebrew** after releasing, never trust `swift build` alone.
- **Helperless mode is not supported.** The privileged helper is auto-installed on first launch and auto-updated on version mismatch. All helperless fallbacks (direct `/sbin/route`, AppleScript) have been removed — every route-mutating operation requires the helper.
- **Helper readiness must be authoritative everywhere** — startup, refresh, reroute, DNS refresh, and hosts file updates must all refuse to proceed when the helper is not verified ready. Do not reintroduce route or hosts fallbacks that bypass the helper state machine.
- **SMAppService.register() does NOT replace existing helper binaries** — when updating, always route to the legacy AppleScript path that does actual `cp` + `launchctl bootout/bootstrap`.
- **Homebrew cask has preflight/postflight** — `pkill -x VPNBypass` before upgrade and `open` after. No manual restart needed.
- **Ship universal binaries** — both the main app and the privileged helper must be universal (`arm64` + `x86_64`) so Intel Macs can launch. `swift build --arch arm64 --arch x86_64` outputs to `.build/apple/Products/Release`, while the helper needs separate arch builds plus `lipo`.
- **Menu bar template images use ONLY the alpha channel** — luminance/color is ignored. Background alpha=0, shape alpha=255. Must be 8-bit PNG (CoreGraphics rejects 16-bit). Render from SVG via `rsvg-convert`.
- **Settings window Dock icon** — menu bar-only apps (LSUIElement) have no Dock icon, so minimized windows vanish. Fix: toggle `NSApp.setActivationPolicy(.regular)` when settings opens, `.accessory` when it closes.
- **CI handles releases end-to-end** — pushing a `v*` tag triggers `.github/workflows/release.yml` which builds the DMG, creates the GitHub release, AND updates the Homebrew cask. Do NOT manually create releases or update the cask — CI will overwrite them. Just commit, tag, push.
- **Test the stale-helper upgrade path after release** — especially with VPN already connected and an older helper still installed. Expected flow: helper preflight on startup, admin prompt if needed, helper update, route apply, and DNS refresh timer start automatically.
- **"Password on every boot" is usually a disabled Login Item** — on macOS Sonoma+, users can disable VPN Bypass's background item in System Settings → General → Login Items & Extensions. When disabled, the helper daemon is blocked by macOS, causing the app to re-prompt for admin on every launch. The fix is enabling the toggle, not a code change. See #25.

## Self-Improving Configuration

This file should evolve as we work together:
1. Track coding patterns and preferences
2. Note corrections made to suggestions
3. Update periodically with learned preferences

## ⚠️ Security Notice

> **Do not commit secrets to the repository or to the live app.**
> Always use secure standards to transmit sensitive information.
> Use environment variables, secret managers, or secure vaults for credentials.

**🔍 Security Audit Recommendation:** When making changes that involve authentication, data handling, API endpoints, or dependencies, proactively offer to perform a security review of the affected code.