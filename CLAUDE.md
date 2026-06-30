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

**Releases are fully automatic from Conventional Commits — do NOT bump or tag by hand.**

Just merge PRs to `main` with conventional commit messages. On every push to `main`,
`.github/workflows/auto-tag.yml` scans commits since the last `v*` tag and bumps:
- `feat:` → **minor** (e.g. 2.8.1 → 2.9.0)
- `fix:` / `chore:` / anything else → **patch** (2.8.1 → 2.8.2)
- `type!:` or `BREAKING CHANGE` → **major** (2.8.1 → 3.0.0)

It creates the `vX.Y.Z` tag and dispatches `.github/workflows/release.yml`, which:
- Builds the universal DMG (arm64 + x86_64) and stamps the version into Info.plist at build time
- Creates the GitHub Release with the DMG
- Updates the Homebrew cask in `homebrew-vpn-bypass` repo

**Do NOT** run `bump-version.sh`, create tags, create GitHub releases, upload DMGs, or
update the cask manually — `auto-tag.yml` + `release.yml` own the whole pipeline and will
overwrite manual work. `bump-version.sh` is retained only for the rare manual/local build.

The version badge in README.md is the dynamic `github/v/release` shield, so it needs no bump.

After CI completes: `brew update && brew upgrade --cask vpn-bypass` to install locally.

**Version architecture**: The app reads its version from `CFBundleShortVersionString` at runtime (not hardcoded). CI stamps it from the git tag. `bump-version.sh` keeps `Info.plist` and `README.md` badge in sync for local builds.

## Best Practices

- **Write clean code**: Prioritize readability and maintainability
- **Handle errors properly**: Don't ignore errors, handle them appropriately
- **Consider security**: Review code for potential security vulnerabilities
- **Conventional commits**: Use conventional commit messages (feat:, fix:, docs:, chore:, refactor:, test:, style:)
- **Semantic versioning**: Follow semver (MAJOR.MINOR.PATCH) for version numbers

## Learned Patterns

- **Releases are auto-tagged from Conventional Commits** — `.github/workflows/auto-tag.yml` computes the next version on every push to `main` (`feat:`→minor, `fix:`/other→patch, `!`/`BREAKING CHANGE`→major), tags `vX.Y.Z`, and dispatches `release.yml`. NEVER hand-tag or run `bump-version.sh` for a normal release; just merge with a conventional commit message. (`bump-version.sh` is kept only for manual/local builds — the old version-desync risk from #15 no longer applies to CI releases.)
- **Version display is dynamic** — do NOT hardcode version strings in Swift code. The app reads from the bundle's `CFBundleShortVersionString` at runtime.
- **Always test via Homebrew** after releasing, never trust `swift build` alone.
- **Helperless mode is not supported.** The privileged helper is auto-installed on first launch and auto-updated on version mismatch. All helperless fallbacks (direct `/sbin/route`, AppleScript) have been removed — every route-mutating operation requires the helper.
- **Helper readiness must be authoritative everywhere** — startup, refresh, reroute, DNS refresh, and hosts file updates must all refuse to proceed when the helper is not verified ready. Do not reintroduce route or hosts fallbacks that bypass the helper state machine.
- **SMAppService.register() does NOT replace existing helper binaries** — when updating, always route to the legacy AppleScript path that does actual `cp` + `launchctl bootout/bootstrap`.
- **Homebrew cask has preflight/postflight** — `pkill -x VPNBypass` before upgrade and `open` after. No manual restart needed.
- **Ship universal binaries** — both the main app and the privileged helper must be universal (`arm64` + `x86_64`) so Intel Macs can launch. `swift build --arch arm64 --arch x86_64` outputs to `.build/apple/Products/Release`, while the helper needs separate arch builds plus `lipo`.
- **Menu bar template images use ONLY the alpha channel** — luminance/color is ignored. Background alpha=0, shape alpha=255. Must be 8-bit PNG (CoreGraphics rejects 16-bit). Render from SVG via `rsvg-convert`.
- **Settings window Dock icon** — menu bar-only apps (LSUIElement) have no Dock icon, so minimized windows vanish. Fix: toggle `NSApp.setActivationPolicy(.regular)` when settings opens, `.accessory` when it closes.
- **CI handles releases end-to-end** — merging a Conventional Commit to `main` triggers `auto-tag.yml` (version bump + tag) which chains into `release.yml` (DMG + GitHub release + Homebrew cask). Do NOT manually create tags, releases, or update the cask — CI will overwrite them. Just merge with a `feat:`/`fix:` message. A manually-pushed `v*` tag still triggers `release.yml` directly (escape hatch).
- **Test the stale-helper upgrade path after release** — especially with VPN already connected and an older helper still installed. Expected flow: helper preflight on startup, admin prompt if needed, helper update, route apply, and DNS refresh timer start automatically.
- **Some VPNs route via interface link, not IP gateway** — Cisco Secure Client sets the default route to `link#N` (an interface reference) instead of an IP address. `route -n get default` shows `interface: utunX` with no `gateway:` line. VPN Only mode handles this via `iface:<interface>` convention: the helper uses `route add -host <dest> -interface utunX` instead of an IP gateway. See #26.
- **VPN interface flaps cause spurious notifications.** `NWPathMonitor` and `ifconfig` can momentarily miss the VPN interface during network transitions. `checkVPNStatus()` must recheck after a short delay (1.5s) before committing to a disconnect state, otherwise the app fires false disconnect→reconnect notifications.
- **Wildcard domains (`*.example.com`) are impossible at the macOS routing level.** macOS routing tables are IP-based — you can only route specific IPs or CIDR ranges, not domain patterns. `/etc/hosts` also does not support wildcards. Any wildcard implementation can only resolve the base domain's IPs, not actual subdomains with different IPs. Don't reintroduce this feature.
- **Helper launchd plist MUST have `RunAtLoad: true`** — without it, the daemon relies on on-demand XPC activation, which macOS blocks when the Login Items toggle is disabled. Homebrew cask upgrades re-sign the app, causing macOS to reset the toggle, which re-breaks the helper on every boot. `RunAtLoad: true` makes the daemon start unconditionally — no Login Items dependency. NEVER set `RunAtLoad` back to `false`. See #25.

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
---

*Generated by [LynxPrompt](https://lynxprompt.com) CLI*


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
