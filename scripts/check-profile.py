#!/usr/bin/env python3
"""Check that a provisioning profile fits the binary it is about to be embedded in.

    check-profile.py PROFILE --id com.geiserx.vpn-bypass --entitlements entitlements/app.entitlements \\
        --cert-sha1 <signing certificate SHA-1>

On macOS 26 and later AMFI kills a binary whose restricted entitlements its embedded profile does not
cover, at launch, before any of our code runs (design 3.2). So the profile must be:
- for the team's id: application-identifier is 624WUVM8B4.<id>;
- for the signing certificate: its SHA-1 is among DeveloperCertificates;
- not expired;
- a Developer ID profile (ProvisionsAllDevices), so it is valid on any Mac;
- a superset of the signed entitlements: every value we sign with is allowed.

PROFILE is the signed .provisionprofile, decoded with `security cms -D`: a plain plist is refused, since
AMFI would not read it. --plist reads an already decoded plist instead (tests).
Prints the profile's name and expiry only, never its content. Exit 0 fits, 1 does not, 2 usage.
"""
import argparse
import datetime
import hashlib
import plistlib
import subprocess
import sys

TEAM = "624WUVM8B4"


def load(path: str, decoded: bool) -> dict:
    if decoded:
        return plistlib.load(open(path, "rb"))
    raw = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
    return plistlib.loads(raw)


def allowed(key: str, wanted, have) -> bool:
    if isinstance(wanted, list):
        return isinstance(have, list) and set(wanted) <= set(have)
    if key.endswith("application-identifier") and isinstance(have, str) and have.endswith("*"):
        return isinstance(wanted, str) and wanted.startswith(have[:-1])
    return have == wanted


def problems(profile: dict, ident: str, entitlements: dict, cert_sha1: str, now: datetime.datetime) -> list:
    out = []
    granted = profile.get("Entitlements", {})
    if granted.get("com.apple.application-identifier") != f"{TEAM}.{ident}":
        out.append(f"it is for {granted.get('com.apple.application-identifier')!r}, not {TEAM}.{ident}")
    if TEAM not in profile.get("TeamIdentifier", []):
        out.append(f"its team is not {TEAM}")
    shas = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    if cert_sha1.upper() not in shas:
        out.append("it does not hold the signing certificate")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=None) <= now:
        out.append(f"it expired ({expires})")
    if profile.get("ProvisionsAllDevices") is not True:
        out.append("it is not a Developer ID profile (ProvisionsAllDevices is not true)")
    for key, value in entitlements.items():
        if key.startswith("com.apple.security."):
            continue  # sandbox, network, Apple Events: not restricted, no profile needed
        if key not in granted or not allowed(key, value, granted[key]):
            out.append(f"it does not allow {key} = {value!r}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("profile")
    ap.add_argument("--id", required=True)
    ap.add_argument("--entitlements", required=True)
    ap.add_argument("--cert-sha1", required=True)
    ap.add_argument("--plist", action="store_true", help="PROFILE is an already decoded plist (tests)")
    a = ap.parse_args()
    try:
        profile = load(a.profile, a.plist)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as e:
        print(f"error: {a.profile} does not decode as a provisioning profile ({type(e).__name__})", file=sys.stderr)
        return 1
    entitlements = plistlib.load(open(a.entitlements, "rb"))
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    found = problems(profile, a.id, entitlements, a.cert_sha1, now)
    for p in found:
        print(f"error: profile {a.profile} does not fit {a.id}: {p}", file=sys.stderr)
    if found:
        return 1
    print(f"profile ok: {profile.get('Name')!r} for {TEAM}.{a.id}, expires {profile.get('ExpirationDate')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
