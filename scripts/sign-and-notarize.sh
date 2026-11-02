#!/usr/bin/env bash
# Sign VPN Bypass with the Developer ID, notarize it with Apple and staple the ticket.
#
#   scripts/sign-and-notarize.sh app [--entitlements VPNBypass.entitlements] "VPN Bypass.app"
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
target="${1:?$usage}"
[ "$#" -eq 1 ] || { echo "$usage" >&2; exit 1; }
[ -e "$target" ] || { echo "error: $target does not exist" >&2; exit 1; }

: "${SIGN_IDENTITY:?SIGN_IDENTITY is not set}"
[ "$SIGN_IDENTITY" != "-" ] || { echo "error: SIGN_IDENTITY is ad-hoc (-); releases need the Developer ID" >&2; exit 1; }
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

sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

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
    if [ -n "$entitlements" ]; then
      sign --entitlements "$entitlements" "$target"
      # What the signature carries must be the file, key for key.
      codesign -d --entitlements - --xml "$target" > "$work/signed.plist"
      plutil -convert json -o "$work/signed.json" "$work/signed.plist"
      plutil -convert json -o "$work/wanted.json" "$entitlements"
      if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
          "$work/signed.json" "$work/wanted.json"; then
        echo "error: the app's signed entitlements differ from $entitlements" >&2
        exit 1
      fi
    else
      sign "$target"
    fi
    codesign --verify --deep --strict --verbose=2 "$target"
    codesign --verify -R="$helper_requirement" "$target"
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
