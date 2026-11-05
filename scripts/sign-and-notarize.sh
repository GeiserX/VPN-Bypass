#!/usr/bin/env bash
# Sign VPN Bypass with the Developer ID, notarize it with Apple and staple the ticket.
#
#   scripts/sign-and-notarize.sh app --entitlements entitlements/app.entitlements "VPN Bypass.app"
#   scripts/sign-and-notarize.sh dmg dist/VPN-Bypass-X.Y.Z.dmg
#
# Needs SIGN_IDENTITY (the certificate's SHA-1, which works where a name with accents
# does not) and notary credentials: NOTARY_PROFILE (a `notarytool store-credentials`
# profile), or APPLE_ID, APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID.
# A missing one is an error, never a fallback to ad-hoc: the helper only accepts an app
# signed by our team, so an ad-hoc release could not use its own helper.
#
# --entitlements signs the app bundle (not the helper or vpnb) with that file. The app needs
# com.apple.security.automation.apple-events to read the browser's front tab: under the
# hardened runtime, Apple Events are refused without it. The signed entitlements are read
# back and must equal the file.
#
# The app and its per-app routing extension (Contents/Library/SystemExtensions) carry Network
# Extension entitlements, which AMFI honours only with an embedded provisioning profile: macOS 26
# and later kill the binary at launch without one. So app mode also needs the two Developer ID
# profiles, as paths: PROVISIONING_PROFILE_APP (com.geiserx.vpn-bypass) and
# PROVISIONING_PROFILE_PROXY (com.geiserx.vpn-bypass.proxy). scripts/check-profile.py checks each
# fits its binary (id, certificate, expiry, entitlements) before anything is signed. The extension
# is signed with entitlements/proxy.entitlements.
set -euo pipefail

usage="usage: $0 app [--entitlements FILE] PATH | dmg PATH"
mode="${1:?$usage}"
shift
entitlements=""
if [ "${1:-}" = "--entitlements" ]; then
  [ "$mode" = "app" ] || { echo "error: --entitlements is for app only" >&2; exit 1; }
  entitlements="${2:?$usage}"
  shift 2
  [ -f "$entitlements" ] || { echo "error: entitlements file $entitlements does not exist" >&2; exit 1; }
  plutil -lint -s "$entitlements" || { echo "error: $entitlements is not a valid plist" >&2; exit 1; }
fi
[ "$mode" != "app" ] || [ -n "$entitlements" ] || { echo "error: app needs --entitlements" >&2; exit 1; }
target="${1:?$usage}"
[ "$#" -eq 1 ] || { echo "$usage" >&2; exit 1; }
[ -e "$target" ] || { echo "error: $target does not exist" >&2; exit 1; }

: "${SIGN_IDENTITY:?SIGN_IDENTITY is not set}"
[ "$SIGN_IDENTITY" != "-" ] || { echo "error: SIGN_IDENTITY is ad-hoc (-); releases need the Developer ID" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
proxy_id=com.geiserx.vpn-bypass.proxy
proxy_entitlements="$here/../entitlements/proxy.entitlements"
if [ "$mode" = "app" ]; then
  for name in PROVISIONING_PROFILE_APP PROVISIONING_PROFILE_PROXY; do
    [ -n "${!name:-}" ] || { echo "error: $name (path to a provisioning profile) is not set" >&2; exit 1; }
    [ -f "${!name}" ] || { echo "error: $name: ${!name} does not exist" >&2; exit 1; }
  done
  proxy="$target/Contents/Library/SystemExtensions/$proxy_id.systemextension"
  [ -d "$proxy" ] || { echo "error: $proxy is missing" >&2; exit 1; }
  # The profiles must hold the signing certificate: its SHA-1, whether SIGN_IDENTITY is the SHA-1
  # or the identity's name.
  # awk reads to the end: exiting at the match would leave security writing into a closed pipe,
  # and its SIGPIPE ends the script under pipefail (exit 141, no message).
  sign_sha1=$(security find-identity -v -p codesigning | awk -v id="$SIGN_IDENTITY" '!found && index($0, id) {print $2; found = 1}')
  [ -n "$sign_sha1" ] || { echo "error: no valid codesigning identity matches SIGN_IDENTITY" >&2; exit 1; }
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary_auth=(--keychain-profile "$NOTARY_PROFILE")
else
  missing="set NOTARY_PROFILE, or APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID"
  : "${APPLE_ID:?$missing}" "${APPLE_PASSWORD:?$missing}" "${APPLE_TEAM_ID:?$missing}"
  notary_auth=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The requirement the helper enforces on the app (HelperAuthPolicy.callerRequirement; a
# test keeps the two equal). A certificate from another team signs fine but fails this.
helper_requirement='anchor apple generic and identifier "com.geiserx.vpn-bypass" and certificate leaf[subject.OU] = "624WUVM8B4"'
proxy_requirement="anchor apple generic and identifier \"$proxy_id\" and certificate leaf[subject.OU] = \"624WUVM8B4\""

sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

# What the signature of $1 carries must be the file $2, key for key.
check_signed_entitlements() {
  codesign -d --entitlements - --xml "$1" > "$work/signed.plist"
  plutil -convert json -o "$work/signed.json" "$work/signed.plist"
  plutil -convert json -o "$work/wanted.json" "$2"
  if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
      "$work/signed.json" "$work/wanted.json"; then
    echo "error: the signed entitlements of $1 differ from $2" >&2
    exit 1
  fi
}

# Check a profile fits, then embed it where AMFI looks: <bundle>/Contents/embedded.provisionprofile.
embed_profile() {
  python3 -I "$here/check-profile.py" "$1" --id "$2" --entitlements "$3" --cert-sha1 "$sign_sha1"
  cp "$1" "$4/Contents/embedded.provisionprofile"
}

# notarytool can exit 0 for a rejected submission, so read the status it reports.
notarize() {
  local out status
  out=$(xcrun notarytool submit "$1" "${notary_auth[@]}" --wait --output-format json)
  status=$(plutil -extract status raw -o - - <<<"$out")
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization of $1 ended as $status" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$out")" "${notary_auth[@]}" >&2 || true
    exit 1
  fi
}

case "$mode" in
  app)
    # Inside out: the bundle's signature seals the nested executables, so they go first.
    sign --identifier com.geiserx.vpnbypass.helper "$target/Contents/MacOS/com.geiserx.vpnbypass.helper"
    sign --identifier com.geiserx.vpn-bypass.vpnb "$target/Contents/MacOS/vpnb"
    embed_profile "$PROVISIONING_PROFILE_PROXY" "$proxy_id" "$proxy_entitlements" "$proxy"
    sign --entitlements "$proxy_entitlements" "$proxy"
    check_signed_entitlements "$proxy" "$proxy_entitlements"
    embed_profile "$PROVISIONING_PROFILE_APP" com.geiserx.vpn-bypass "$entitlements" "$target"
    sign --entitlements "$entitlements" "$target"
    check_signed_entitlements "$target" "$entitlements"
    codesign --verify --deep --strict --verbose=2 "$target"
    codesign --verify -R="$helper_requirement" "$target"
    codesign --verify -R="$proxy_requirement" "$proxy"
    ditto -c -k --keepParent "$target" "$work/app.zip"
    notarize "$work/app.zip"
    xcrun stapler staple "$target"
    spctl --assess --type execute --verbose=2 "$target"
    ;;
  dmg)
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$target"
    notarize "$target"
    xcrun stapler staple "$target"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
    ;;
  *)
    echo "$usage" >&2
    exit 1
    ;;
esac
