#!/usr/bin/env bash
# Sign VPN Bypass with the Developer ID, notarize it with Apple and staple the ticket.
#
#   scripts/sign-and-notarize.sh app "VPN Bypass.app"
#   scripts/sign-and-notarize.sh dmg dist/VPN-Bypass-X.Y.Z.dmg
#
# Needs SIGN_IDENTITY (the certificate's SHA-1, which works where a name with accents
# does not) and notary credentials: NOTARY_PROFILE (a `notarytool store-credentials`
# profile), or APPLE_ID, APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID.
# A missing one is an error, never a fallback to ad-hoc: the helper only accepts an app
# signed by our team, so an ad-hoc release could not use its own helper.
set -euo pipefail

usage="usage: $0 app|dmg PATH"
mode="${1:?$usage}"
target="${2:?$usage}"
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
    sign "$target"
    codesign --verify --deep --strict --verbose=2 "$target"
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
