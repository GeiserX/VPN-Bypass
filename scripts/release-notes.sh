#!/usr/bin/env bash
# Writes the GitHub release notes for one version to stdout. release.yml calls it.
#
#   scripts/release-notes.sh <version> <dmg sha256>
#
# Run from the repository root, with the version's tag already created (auto-tag.yml tags
# before it dispatches the release). GITHUB_REPOSITORY (owner/name) builds the compare link.
#
# If docs/release-notes/<version>.md exists, its content goes first, above "What's Changed":
# that is where a version tells the people upgrading what changes for them. The change lists
# come from the commit subjects since the previous tag, every one of them: a major built from
# thirty PRs lists thirty entries.
set -euo pipefail

VERSION_NUMBER="${1:?usage: release-notes.sh <version> <sha256>}"
SHA256="${2:?usage: release-notes.sh <version> <sha256>}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set (owner/name)}"
VERSION="v$VERSION_NUMBER"
NOTES_FILE="docs/release-notes/$VERSION_NUMBER.md"

PREV_TAG=$(git tag -l "v*" --sort=-version:refname | sed -n '2p')
if [ -z "$PREV_TAG" ]; then
  PREV_TAG=$(git rev-list --max-parents=0 HEAD)
fi
echo "📝 Generating changelog from $PREV_TAG to $VERSION" >&2

if [ -f "$NOTES_FILE" ]; then
  echo "📝 Upgrade notes from $NOTES_FILE go first" >&2
  cat "$NOTES_FILE"
  # A file without a final newline would glue its last line to the heading below.
  [ -z "$(tail -c 1 "$NOTES_FILE")" ] || echo ""
  echo ""
fi

echo "## What's Changed"
echo ""

# Features
FEATURES=$(git log "$PREV_TAG"..HEAD --pretty=format:"- %s" --grep="^feat" 2>/dev/null || true)
if [ -n "$FEATURES" ]; then
  echo "### ✨ Features"
  echo "$FEATURES"
  echo ""
fi

# Fixes
FIXES=$(git log "$PREV_TAG"..HEAD --pretty=format:"- %s" --grep="^fix" 2>/dev/null || true)
if [ -n "$FIXES" ]; then
  echo "### 🐛 Bug Fixes"
  echo "$FIXES"
  echo ""
fi

# Other changes
OTHERS=$(git log "$PREV_TAG"..HEAD --pretty=format:"- %s" --invert-grep --grep="^feat" --invert-grep --grep="^fix" 2>/dev/null || true)
if [ -n "$OTHERS" ]; then
  echo "### 🔧 Other Changes"
  echo "$OTHERS"
  echo ""
fi

echo "---"
echo ""
echo "## Installation"
echo ""
echo "### Homebrew (recommended)"
echo '```bash'
echo "brew tap GeiserX/vpn-bypass"
echo "brew install --cask vpn-bypass"
echo '```'
echo ""
echo "### Manual Download"
echo "Download \`VPN-Bypass-$VERSION_NUMBER.dmg\` from the assets below."
echo ""
echo "---"
echo ""
echo "**SHA256:** \`$SHA256\`"
echo ""
echo "**Full Changelog**: https://github.com/$REPO/compare/$PREV_TAG...$VERSION"
