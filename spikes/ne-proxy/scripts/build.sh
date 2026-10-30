#!/usr/bin/env bash
# Build the spike bundle, unsigned, universal. Run on the build Mac (not the MacBook).
#   scripts/build.sh            -> build/VPN Bypass NE Spike.app
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/VPN Bypass NE Spike.app"
ext_id=com.geiserx.vpn-bypass.spike.proxy
ext="$app/Contents/Library/SystemExtensions/$ext_id.systemextension"
products=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

swift build -c release --arch arm64 --arch x86_64

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$ext/Contents/MacOS"
cp bundle/App-Info.plist "$app/Contents/Info.plist"
cp bundle/Proxy-Info.plist "$ext/Contents/Info.plist"
cp "$products/VPNBypassNESpike" "$app/Contents/MacOS/"
cp "$products/spike-fetch" "$app/Contents/MacOS/"
cp "$products/$ext_id" "$ext/Contents/MacOS/"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Checks that would otherwise only show at activation.
fail() { echo "error: $*" >&2; exit 1; }
[ "$(plutil -extract CFBundlePackageType raw -o - "$ext/Contents/Info.plist")" = SYSX ] || fail "extension is not SYSX"
cls=$(plutil -extract NetworkExtension.NEProviderClasses.com\\.apple\\.networkextension\\.app-proxy raw -o - "$ext/Contents/Info.plist") \
  || fail "no app-proxy NEProviderClasses entry"
for arch in arm64 x86_64; do
  otool -arch "$arch" -ov "$ext/Contents/MacOS/$ext_id" | awk '$1 == "name" {print $3}' | grep -qxF "$cls" \
    || fail "$arch: class $cls named in NEProviderClasses is not in the extension binary"
done
for bin in "$app/Contents/MacOS/VPNBypassNESpike" "$app/Contents/MacOS/spike-fetch" "$ext/Contents/MacOS/$ext_id"; do
  archs=$(lipo -archs "$bin")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$bin is not universal ($archs)"
done
# The extension must not link the app's resource bundle machinery or anything beyond the system.
if otool -L "$ext/Contents/MacOS/$ext_id" | grep -E '^[[:space:]]' | grep -v -E '^[[:space:]]+(/System/Library/|/usr/lib/)'; then
  fail "extension links a non-system library"
fi
echo "built: $app"
