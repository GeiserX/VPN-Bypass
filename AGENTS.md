# VPNBypass - AI Agent Instructions

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
- Always run and test locally after making changes
- Check logs when build or commit finishes
- Ensure all tests pass before committing
- Match the codebase's existing style and patterns
- Confirm before making significant changes

### Important Files to Read First
Before making changes, read these files to understand the project:
- README.md
- CHANGELOG.md

### CI/CD & Infrastructure
- **CI/CD Platform**: GitHub Actions

### Releasing New Versions
Use the version bump script to update all version locations:

```bash
# Bump version (updates Info.plist, SettingsView.swift, README.md, Casks/)
./scripts/bump-version.sh 1.3.0

# Update CHANGELOG.md manually with release notes

# Commit and tag
git add -A && git commit -m "chore: release v1.3.0"
git tag v1.3.0
git push && git push origin v1.3.0
```

The tag push triggers GitHub Actions which:
1. Builds the app and creates DMG
2. Creates a GitHub Release with the DMG
3. Updates the Homebrew cask in `homebrew-vpn-bypass` repo automatically

## Best Practices

- **Write clean code**: Prioritize readability and maintainability
- **Handle errors properly**: Don't ignore errors, handle them appropriately
- **Consider security**: Review code for potential security vulnerabilities
- **Conventional commits**: Use conventional commit messages (feat:, fix:, docs:, chore:, refactor:, test:, style:)
- **Semantic versioning**: Follow semver (MAJOR.MINOR.PATCH) for version numbers

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