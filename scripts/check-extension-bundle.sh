#!/usr/bin/env bash
# Check the per-app routing system extension inside a built VPN Bypass.app: the mistakes that
# would otherwise show only when macOS activates it, on a user's Mac.
#
#   scripts/check-extension-bundle.sh "VPN Bypass.app"
#
# `make bundle` runs it, so CI (job "build and launch app") and every release do too.
set -euo pipefail

app="${1:?usage: $0 PATH/TO/VPN\ Bypass.app}"
id=com.geiserx.vpn-bypass.proxy
ext="$app/Contents/Library/SystemExtensions/$id.systemextension"
info="$ext/Contents/Info.plist"
bin="$ext/Contents/MacOS/$id"

fail() { echo "error: extension bundle: $*" >&2; exit 1; }
read_key() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

[ -f "$info" ] || fail "$info is missing"
[ -x "$bin" ] || fail "$bin is missing or not executable"
[ "$(read_key CFBundlePackageType "$info")" = SYSX ] || fail "CFBundlePackageType is not SYSX"
[ "$(read_key CFBundleIdentifier "$info")" = "$id" ] || fail "CFBundleIdentifier is not $id"
[ "$(read_key CFBundleExecutable "$info")" = "$id" ] || fail "CFBundleExecutable is not $id"
[ -n "$(read_key NSSystemExtensionUsageDescription "$info")" ] || fail "no NSSystemExtensionUsageDescription"
[ -f "$ext/Contents/Resources/$(read_key CFBundleIconFile "$info").icns" ] \
  || fail "the icon CFBundleIconFile names is not in Contents/Resources (the approval alert shows a blank icon)"
# macOS replaces an installed extension only when its version changes: it must move with the app.
for key in CFBundleShortVersionString CFBundleVersion; do
  [ "$(read_key "$key" "$info")" = "$(read_key "$key" "$app/Contents/Info.plist")" ] \
    || fail "$key differs from the app's"
done
cls=$(read_key 'NetworkExtension.NEProviderClasses.com\.apple\.networkextension\.app-proxy' "$info") \
  || fail "no NetworkExtension > NEProviderClasses > com.apple.networkextension.app-proxy entry"
# The class must be in the binary under that exact Objective-C name, or activation fails.
# grep reads the whole listing (no -q): with -q it exits at the first match, otool or awk gets
# SIGPIPE, and pipefail turns a found class into a failure.
for arch in arm64 x86_64; do
  lipo "$bin" -verify_arch "$arch" || fail "the binary has no $arch slice"
  otool -arch "$arch" -ov "$bin" | awk '$1 == "name" {print $3}' | grep -xF "$cls" >/dev/null \
    || fail "$arch: class $cls, named in NEProviderClasses, is not in the binary"
done
# The extension links the system and nothing else: no copy of the app's frameworks or resources.
# (otool prints one unindented header per architecture, then the libraries indented.)
if otool -L "$bin" | grep -E '^[[:space:]]' | grep -v -E '^[[:space:]]+(/System/Library/|/usr/lib/)'; then
  fail "the binary links a library outside the system"
fi
echo "extension bundle ok: $id $(read_key CFBundleShortVersionString "$info"), provider class $cls"
