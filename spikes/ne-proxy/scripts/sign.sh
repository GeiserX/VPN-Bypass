#!/usr/bin/env bash
# Sign the spike inside out with per-binary entitlements and embedded profiles, notarize, staple, verify.
# Run on the Mac that holds the Developer ID identity.
#
#   SIGN_IDENTITY=<cert SHA-1> PROFILE_DIR=<dir with the two profiles> NOTARY_PROFILE=<notarytool profile> \
#     scripts/sign.sh "build/VPN Bypass NE Spike.app"
#   SKIP_NOTARIZE=1 ...   signs and checks only
set -euo pipefail

app="${1:?usage: $0 APP}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY (certificate SHA-1) is not set}"
: "${PROFILE_DIR:?PROFILE_DIR is not set}"
# Relative paths are the caller's: resolve them before moving to the package directory.
[ -d "$app" ] || { echo "error: $app is not a directory" >&2; exit 1; }
[ -d "$PROFILE_DIR" ] || { echo "error: $PROFILE_DIR is not a directory" >&2; exit 1; }
app=$(cd "$app" && pwd)
PROFILE_DIR=$(cd "$PROFILE_DIR" && pwd)
cd "$(dirname "$0")/.."
team=624WUVM8B4
app_id=com.geiserx.vpn-bypass.spike
ext_id=com.geiserx.vpn-bypass.spike.proxy
ext="$app/Contents/Library/SystemExtensions/$ext_id.systemextension"
app_profile="$PROFILE_DIR/vpn-bypass-spike-app.provisionprofile"
ext_profile="$PROFILE_DIR/vpn-bypass-spike-proxy.provisionprofile"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "error: $*" >&2; exit 1; }
[ -d "$ext" ] || fail "$ext is missing"

# A profile fit for a binary: right app id, our team, the signing certificate inside, not expired,
# and every signed entitlement allowed by it.
check_profile() {
  local profile=$1 id=$2 entitlements=$3 decoded="$work/$(basename "$1").plist"
  security cms -D -i "$profile" > "$decoded" 2>/dev/null || fail "$profile does not decode"
  [ "$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$decoded")" = "$team.$id" ] \
    || fail "$profile is not for $team.$id"
  local found=0 i=0 sha
  while sha=$(plutil -extract DeveloperCertificates.$i raw -o - "$decoded" 2>/dev/null); do
    [ "$(base64 -d <<<"$sha" | shasum -a 1 | awk '{print toupper($1)}')" = "$(tr a-z A-Z <<<"$SIGN_IDENTITY")" ] && found=1
    i=$((i + 1))
  done
  [ $found = 1 ] || fail "$profile does not contain the signing certificate $SIGN_IDENTITY"
  local expires
  expires=$(plutil -extract ExpirationDate raw -o - "$decoded")
  [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \< "$expires" ] || fail "$profile expired $expires"
  python3 -I - "$decoded" "$entitlements" <<'PY' || fail "$profile does not allow every entitlement in $entitlements"
import plistlib, sys
allowed = plistlib.load(open(sys.argv[1], "rb"))["Entitlements"]
wanted = plistlib.load(open(sys.argv[2], "rb"))
ok = True
for k, v in wanted.items():
    a = allowed.get(k)
    if isinstance(v, list):
        good = isinstance(a, list) and set(v) <= set(a)
    else:
        good = a == v or (k.endswith("application-identifier") and isinstance(a, str) and a.endswith("*") and v.startswith(a[:-1]))
    if not good:
        print(f"  not allowed: {k}={v!r}", file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
PY
  echo "profile ok: $(basename "$profile") -> $team.$id"
}

check_profile "$ext_profile" "$ext_id" entitlements/proxy.entitlements
check_profile "$app_profile" "$app_id" entitlements/app.entitlements

sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

# Inside out: the outer signature seals what is nested.
sign --identifier com.geiserx.vpn-bypass.spike.fetch "$app/Contents/MacOS/spike-fetch"
cp "$ext_profile" "$ext/Contents/embedded.provisionprofile"
sign --entitlements entitlements/proxy.entitlements "$ext"
cp "$app_profile" "$app/Contents/embedded.provisionprofile"
sign --entitlements entitlements/app.entitlements "$app"

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify -R="anchor apple generic and identifier \"$app_id\" and certificate leaf[subject.OU] = \"$team\"" "$app"
codesign --verify -R="anchor apple generic and identifier \"$ext_id\" and certificate leaf[subject.OU] = \"$team\"" "$ext"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "signed, not notarized: $app"
  exit 0
fi
: "${NOTARY_PROFILE:?NOTARY_PROFILE is not set}"
ditto -c -k --keepParent "$app" "$work/app.zip"
out=$(xcrun notarytool submit "$work/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
status=$(plutil -extract status raw -o - - <<<"$out")
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$out")" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fail "notarization ended as $status"
fi
echo "notarized: $(plutil -extract id raw -o - - <<<"$out")"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vvv -t execute "$app"
