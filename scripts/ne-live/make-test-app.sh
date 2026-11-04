#!/usr/bin/env bash
# Build the live-test bundle for per-app routing: a copy of a `make bundle` app whose executable is
# ne-driver (main.swift beside this script), signed like a release but not notarized. For a test
# Mac only (the Mac mini: SIP off, AMFI off); never install it anywhere else.
#
#   scripts/ne-live/make-test-app.sh "VPN Bypass.app" "/tmp/out/VPN Bypass NE Test.app" [extension version]
#
# Signing needs SIGN_IDENTITY (certificate SHA-1), PROVISIONING_PROFILE_APP and
# PROVISIONING_PROFILE_PROXY. SIGN_KEYCHAIN names an unlocked keychain holding the identity; codesign
# still finds the identity only when that keychain is also on the search list, so add a temporary one
# there for the build and restore the list afterwards. The optional version is stamped into the
# extension's Info.plist, so a second bundle with a higher one replaces an activated extension (L9).
set -euo pipefail

src="${1:?usage: $0 APP OUT [VERSION]}"
dst="${2:?usage: $0 APP OUT [VERSION]}"
version="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
: "${SIGN_IDENTITY:?SIGN_IDENTITY is not set}"
: "${PROVISIONING_PROFILE_APP:?}" "${PROVISIONING_PROFILE_PROXY:?}"

rm -rf "$dst"
ditto "$src" "$dst"
proxy="$dst/Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension"
if [ -n "$version" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$proxy/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$proxy/Contents/Info.plist"
fi
swiftc -O -swift-version 5 -o "$dst/Contents/MacOS/VPNBypass" "$here/main.swift" "$root"/Sources/VPNBypassPolicy/*.swift

keychain=()
[ -z "${SIGN_KEYCHAIN:-}" ] || keychain=(--keychain "$SIGN_KEYCHAIN")
sign() { codesign --force --options runtime --timestamp=none ${keychain[@]+"${keychain[@]}"} --sign "$SIGN_IDENTITY" "$@"; }
sign --identifier com.geiserx.vpnbypass.helper "$dst/Contents/MacOS/com.geiserx.vpnbypass.helper"
sign --identifier com.geiserx.vpn-bypass.vpnb "$dst/Contents/MacOS/vpnb"
cp "$PROVISIONING_PROFILE_PROXY" "$proxy/Contents/embedded.provisionprofile"
sign --entitlements "$root/entitlements/proxy.entitlements" "$proxy"
cp "$PROVISIONING_PROFILE_APP" "$dst/Contents/embedded.provisionprofile"
sign --entitlements "$root/entitlements/app.entitlements" "$dst"
codesign --verify --deep --strict "$dst"
echo "built $dst (extension $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$proxy/Contents/Info.plist"))"
