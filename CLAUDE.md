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

**A series of PRs ships as ONE release.** Every merge to `main` that touches the app cuts a
release, so a feature series merged PR by PR would publish one version per PR (on 2026-10-01 a
UI redesign cut eleven, 4.13.0 to 4.23.0, which were then deleted and shipped as 5.0.0). Before
the first merge of a series, pause releases; after the last, release once:

```bash
gh variable set AUTO_RELEASE --body false --repo GeiserX/VPN-Bypass   # merges now release nothing
# ... merge the series ...
gh variable set AUTO_RELEASE --body true --repo GeiserX/VPN-Bypass
gh workflow run auto-tag.yml --repo GeiserX/VPN-Bypass -f bump=auto    # or major/minor/patch
```

The manual run bumps from the last tag over every commit since, and `release.yml` writes the
notes from the same range, so the one release lists the whole series.

After CI completes: `brew update && brew upgrade --cask vpn-bypass` to install locally.

**Version architecture**: The app reads its version from `CFBundleShortVersionString` at runtime (not hardcoded). CI stamps it from the git tag. `bump-version.sh` keeps `Info.plist` and `README.md` badge in sync for local builds.

## Best Practices

- **Write clean code**: Prioritize readability and maintainability
- **Handle errors properly**: Don't ignore errors, handle them appropriately
- **Consider security**: Review code for potential security vulnerabilities
- **Conventional commits**: Use conventional commit messages (feat:, fix:, docs:, chore:, refactor:, test:, style:)
- **Semantic versioning**: Follow semver (MAJOR.MINOR.PATCH) for version numbers
- **The service catalogue is best effort.** The catalogue (`Sources/VPNBypassCore/Resources/catalogue/`) gives each user a sensible starting point, not a complete or always-current list. We avoid constant changes to it: no PRs that chase every CDN host or domain shuffle, and no churn. We accept two kinds of change: a new service in a clear category, and a fix for a domain that no longer works. Each user is expected to adjust a service as needed, by adding names to a built-in service from the Lookups page (the Services page lists them and can remove them), or by making a custom service. That is preferred over editing the catalogue. Ids never change: saved configs, `vpnb` and the MCP server refer to them. How to add an entry: the catalogue's `README.md`.

## Learned Patterns

- **Releases are auto-tagged from Conventional Commits** — `.github/workflows/auto-tag.yml` computes the next version on every push to `main` (`feat:`→minor, `fix:`/other→patch, `!`/`BREAKING CHANGE`→major), tags `vX.Y.Z`, and dispatches `release.yml`. NEVER hand-tag or run `bump-version.sh` for a normal release; just merge with a conventional commit message. (`bump-version.sh` is kept only for manual/local builds — the old version-desync risk from #15 no longer applies to CI releases.)
- **Version display is dynamic** — do NOT hardcode version strings in Swift code. The app reads from the bundle's `CFBundleShortVersionString` at runtime.
- **Always test via Homebrew** after releasing, never trust `swift build` alone.
- **Helperless mode is not supported.** The privileged helper is auto-installed on first launch and auto-updated on version mismatch. All helperless fallbacks (direct `/sbin/route`, AppleScript) have been removed — every route-mutating operation requires the helper.
- **Helper readiness must be authoritative everywhere** — startup, refresh, reroute, DNS refresh, and hosts file updates must all refuse to proceed when the helper is not verified ready. Do not reintroduce route or hosts fallbacks that bypass the helper state machine.
- **SMAppService.register() does NOT replace existing helper binaries** — when updating, always route to the legacy AppleScript path that does actual `cp` + `launchctl bootout/bootstrap`.
- **The app restarts itself after an update; the cask has no preflight or postflight.** Homebrew runs a cask's install steps in a sandbox that forbids launching an app (`deny lsopen` in its profile), so a cask can quit the app but never reopen it. `AppUpdateRelauncher` notices on the 30-second tick that the executable at its path is another file, waits until the new bundle's signature verifies, quits through the normal path and reopens the bundle once the old process is gone. `release.yml` strips any preflight or postflight from the tap cask and fails if one survives. A version from before this (5.1.1 or older) keeps running its old code after the upgrade until it is restarted once by hand.
- **Ship universal binaries** — both the main app and the privileged helper must be universal (`arm64` + `x86_64`) so Intel Macs can launch. `swift build --arch arm64 --arch x86_64` outputs to the folder `--show-bin-path` names (`.build/apple/Products/Release` before Swift 6.4, `.build/out/Products/Release` since; the Makefile asks for it), while the helper needs separate arch builds plus `lipo`.
- **Menu bar template images use ONLY the alpha channel** — luminance/color is ignored. Background alpha=0, shape alpha=255. Must be 8-bit PNG (CoreGraphics rejects 16-bit). Render from SVG via `rsvg-convert`.
- **Settings window Dock icon** — menu bar-only apps (LSUIElement) have no Dock icon, so minimized windows vanish. Fix: toggle `NSApp.setActivationPolicy(.regular)` when settings opens, `.accessory` when it closes.
- **CI handles releases end-to-end** — merging a Conventional Commit to `main` triggers `auto-tag.yml` (version bump + tag) which chains into `release.yml` (DMG + GitHub release + Homebrew cask). Do NOT manually create tags, releases, or update the cask — CI will overwrite them. Just merge with a `feat:`/`fix:` message. A manually-pushed `v*` tag still triggers `release.yml` directly (escape hatch).
- **Test the stale-helper upgrade path after release** — especially with VPN already connected and an older helper still installed. Expected flow: helper preflight on startup, admin prompt if needed, helper update, route apply, and DNS refresh timer start automatically.
- **Some VPNs route via interface link, not IP gateway** — Cisco Secure Client sets the default route to `link#N` (an interface reference) instead of an IP address. `route -n get default` shows `interface: utunX` with no `gateway:` line. VPN Only mode handles this via `iface:<interface>` convention: the helper uses `route add -host <dest> -interface utunX` instead of an IP gateway. See #26.
- **VPN interface flaps cause spurious notifications.** `NWPathMonitor` and `ifconfig` can momentarily miss the VPN interface during network transitions. `checkVPNStatus()` must recheck after a short delay (1.5s) before committing to a disconnect state, otherwise the app fires false disconnect→reconnect notifications.
- **Wildcard domains (`*.example.com`) are hard, not impossible: routing is per IP, so a wildcard is turned into IPs at lookup time.** The helper writes `/etc/resolver/<suffix>` (first line `# VPN-BYPASS-MANAGED wildcard resolver`; it never touches a file without it) pointing at its forwarder on `127.0.0.1:53530` (`Helper/WildcardForwarder.swift`). The forwarder asks the upstream the wildcard's route would use (physical DNS bound to the physical interface for Bypass/Direct, the tunnel's DNS bound to its utun for VPN Only or a pinned VPN), adds a tagged host route for each IPv4 answer that passes `WildcardSafetyGuard` and the limiter, and only then replies, so the route is in before the app connects; an address that already has our route to the right gateway is answered at once; one that passed the guard but got no route (limiter, failed install) is taken out of the reply, SERVFAIL when none is left. A busy route queue past the 1.5 s wait keeps the address around the VPN (it takes the VPN, as without wildcards) and withholds it into a tunnel. Wildcard installs go through `HelperTool.priorityLane`, which every batch drains between two writes, so a 1000-route apply does not hold a lookup for seconds. A CNAME chain is folded onto the asked name (A records under it, CNAMEs dropped, shortest TTL), and HTTPS/SVCB answers that point at another name are dropped: mDNSResponder ignores the chained A records in our answer and looks the CNAME target up itself through the normal resolver (DoH to 1.0.0.1 on the 2026-10-29 test), so without the folding the app connects to an address we never routed. The decision is `WildcardLookup.reply` in `WildcardDNS.swift`, tested from the app target. In Custom mode a name under a wildcard that an earlier rule claims (an exact name, the apex too, or a narrower suffix) is in the spec's `excluded`: the forwarder answers it as the upstream does and learns no route, so first match still holds. A wildcard around the VPN learns public addresses only; one into a tunnel (`WildcardSpec.intoTunnel`) may learn private ones, except on another interface's connected network. The helper removes its resolver files at start and on SIGTERM, and launchd restarts it after a crash (`KeepAlive` `SuccessfulExit` false). AAAA gets an empty answer, HTTPS loses `ipv6hint`, TTLs are capped at 300 s, and the DDR probe (`_dns.resolver.arpa`) is answered empty so macOS cannot move to encrypted DNS. Learned routes are `ActiveRoute`s with source `*.suffix`; every apply path must leave them alone (`RouteManager.isLearnedWildcardRoute`, `listedRoutes`). Limits: names sharing an IP share its route; lookups that bypass the system resolver (browser DoH, hardcoded resolvers, iCloud Private Relay) are not seen; a more specific resolver hides part of a wildcard (logged on add); IPv6-only hosts under a wildcard become unreachable; proxy and Tailscale Peer routes cannot take wildcards. Design and evidence: `docs/research/wildcards-and-network-extension.md`.
- **Releases are signed with the Developer ID and notarized.** `release.yml` imports the certificate from repo secrets and `make release` runs `scripts/sign-and-notarize.sh`: helper and `vpnb` first, then the app, notarize and staple it, then the same for the DMG. A missing secret fails the release. The helper accepts only `HelperAuthPolicy.callerRequirement` (the app's identifier signed by team 624WUVM8B4), so nothing may re-sign the app ad hoc afterwards: not the cask, not a fallback in the release.
- **The helper installer must take `com.apple.quarantine` off its copies.** An app from Homebrew or a browser download is quarantined, `cp` carries the mark onto the helper and its launchd plist, and since macOS 27 launchd refuses a quarantined file (`Bootstrap failed: 5`, error 155 in the log). macOS 26 accepts it, so a Mac on 26 does not reproduce this. 5.1.0 shipped with the cask's quarantine clearing removed and left the helper stopped; `HelperManager.legacyInstallShellCommand` strips the mark from both copies. Test an install path on the newest macOS with a bundle that really is quarantined.
- **The helper sets `/etc/hosts` to 0644 on every write; never trust the mode it finds.** Foundation's atomic write keeps the existing mode, and another tool left the file at 0440 on 2026-10-05 (`cp /dev/stdin tmp && mv` from a pipe creates 0440). mDNSResponder runs as `_mdnsresponder`, not in wheel, so it could not open the file and ignored every entry while the log said "hosts file updated". The check is `dscacheutil -q host -a name <pinned name>`: a readable file answers only the pinned IP, an unreadable one answers like `dig`. `HostsFileMode` is the app-side probe; `RouteManager.modifyHostsFile` warns when the file was unreadable.
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

## 🔍 Security Audit Recommendation

When making changes that involve authentication, data handling, API endpoints, or dependencies, proactively offer to perform a security review of the affected code.

*Generated by [LynxPrompt](https://lynxprompt.geiser.cloud) CLI*


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

## Where the tracker syncs

This repo is public, so its tracker syncs only to the private remote named by `sync.remote` in `.beads/config.yaml`. The block above says sync uses "your git remote". Here that never means this GitHub repo. Don't add it as a Dolt remote and don't push `refs/dolt/*` to it.
