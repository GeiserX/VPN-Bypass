#!/bin/bash
# Version bump script for VPN Bypass
# Usage: ./scripts/bump-version.sh 1.2.1

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <new-version>"
    echo "Example: $0 1.2.1"
    exit 1
fi

NEW_VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "🔄 Bumping version to $NEW_VERSION..."

# 1. Info.plist - CFBundleShortVersionString
echo "  → Info.plist"
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string><!-- VERSION -->/<string>$NEW_VERSION<\/string><!-- VERSION -->/" Info.plist 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" Info.plist

# 2. README.md - Badge
echo "  → README.md"
sed -i '' "s/version-[0-9]*\.[0-9]*\.[0-9]*-green/version-$NEW_VERSION-green/" README.md

# 3. Casks/vpn-bypass.rb (optional - usually auto-updated by release workflow)
if [ -f "Casks/vpn-bypass.rb" ]; then
    echo "  → Casks/vpn-bypass.rb"
    sed -i '' "s/version \"[0-9]*\.[0-9]*\.[0-9]*\"/version \"$NEW_VERSION\"/" Casks/vpn-bypass.rb
fi

echo ""
echo "✅ Version bumped to $NEW_VERSION"
echo ""
echo "📝 Remember to:"
echo "   1. Update docs/CHANGELOG.md with release notes"
echo "   2. Commit: git add -A && git commit -m \"chore: bump version to $NEW_VERSION\""
echo "   3. Tag: git tag v$NEW_VERSION"
echo "   4. Push: git push && git push origin v$NEW_VERSION"
