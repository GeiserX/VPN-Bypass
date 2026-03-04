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

**Pre-release checklist** (MUST complete ALL steps before tagging):
1. Run `./scripts/bump-version.sh <version>` — updates Info.plist, README.md badge, and Casks/
2. Update `docs/CHANGELOG.md` with release notes
3. Commit all changes: `git add -A && git commit -m "chore: release v<version>"`
4. Tag: `git tag v<version>`
5. Push: `git push && git push origin v<version>`

```bash
# Example release flow
./scripts/bump-version.sh 1.10.0
# Edit docs/CHANGELOG.md with release notes
git add -A && git commit -m "chore: release v1.10.0"
git tag v1.10.0
git push && git push origin v1.10.0
```

The tag push triggers GitHub Actions which:
1. Updates `Info.plist` version from the git tag (safety net)
2. Builds the app and creates DMG
3. Creates a GitHub Release with the DMG
4. Updates the Homebrew cask in `homebrew-vpn-bypass` repo automatically

**Version architecture**: The app reads its version from `CFBundleShortVersionString` at runtime (not hardcoded). The CI workflow sets this from the git tag. The `bump-version.sh` script keeps `Info.plist` and `README.md` badge in sync for local builds and the repo display.

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