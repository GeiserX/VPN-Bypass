#!/usr/bin/env python3
"""Register the NE spike's bundle ids and mint its Developer ID profiles through the App Store Connect API.

Idempotent: an id, capability or ACTIVE profile that already exists is reused, never re-posted
(re-posting an enabled capability turns the existing profiles INVALID).

    ASC_ISSUER=<issuer id> ASC_KEY_ID=<key id> ASC_KEY=<path to AuthKey_<id>.p8> \
    SIGN_SHA1=<Developer ID Application cert SHA-1> \
      asc-profiles.py [--dry-run] --out ~/DevIDApp-personal-profiles

Writes <out>/vpn-bypass-spike-app.provisionprofile and <out>/vpn-bypass-spike-proxy.provisionprofile,
mode 600. The output directory must be outside any git checkout. Prints ids and states only, never key
material or profile content.
"""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"

# bundle id -> (profile file stem, capabilities it needs)
IDS = {
    "com.geiserx.vpn-bypass.spike": ("vpn-bypass-spike-app", ["SYSTEM_EXTENSION_INSTALL", "NETWORK_EXTENSIONS"]),
    "com.geiserx.vpn-bypass.spike.proxy": ("vpn-bypass-spike-proxy", ["NETWORK_EXTENSIONS"]),
}


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token(issuer: str, kid: str, key: str) -> str:
    header = b64url(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    now = int(time.time())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=msg, capture_output=True, check=True).stdout
    pos, parts = 2, []
    for _ in range(2):  # DER SEQUENCE of two INTEGERs -> raw r||s
        length = der[pos + 1]
        parts.append(der[pos + 2:pos + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        pos += 2 + length
    return f"{header}.{payload}.{b64url(parts[0] + parts[1])}"


class ASC:
    def __init__(self, tok: str, dry: bool):
        self.tok, self.dry = tok, dry

    def call(self, method: str, path: str, body=None):
        if method != "GET" and self.dry:
            print(f"  dry-run: would {method} {path.split('?')[0]}")
            return None
        req = urllib.request.Request(API + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {self.tok}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            sys.exit(f"error: {method} {path.split('?')[0]} -> HTTP {e.code}: {detail[:600]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    out = os.path.abspath(os.path.expanduser(a.out))
    if subprocess.run(["git", "-C", os.path.dirname(out) if not os.path.isdir(out) else out, "rev-parse"],
                      capture_output=True).returncode == 0:
        sys.exit(f"error: {out} is inside a git checkout; profiles never enter git")
    sha1 = os.environ["SIGN_SHA1"].upper()
    asc = ASC(token(os.environ["ASC_ISSUER"], os.environ["ASC_KEY_ID"], os.path.expanduser(os.environ["ASC_KEY"])), a.dry_run)

    cert_id = None
    for c in asc.call("GET", "/certificates?limit=200")["data"]:
        der = base64.b64decode(c["attributes"]["certificateContent"])
        if hashlib.sha1(der).hexdigest().upper() == sha1:
            cert_id = c["id"]
            print(f"certificate {cert_id} {c['attributes']['certificateType']} matches the signing SHA-1")
    if not cert_id:
        sys.exit("error: no certificate on the team matches SIGN_SHA1")

    os.makedirs(out, mode=0o700, exist_ok=True)
    for ident, (stem, caps) in IDS.items():
        found = asc.call("GET", f"/bundleIds?limit=200&filter%5Bidentifier%5D={ident}")["data"]
        found = [b for b in found if b["attributes"]["identifier"] == ident]
        if found:
            bid = found[0]["id"]
            print(f"{ident}: bundle id {bid} exists ({found[0]['attributes']['platform']})")
        else:
            r = asc.call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
                "identifier": ident, "name": stem.replace("-", " "), "platform": "MAC_OS"}}})
            if r is None:
                continue
            bid = r["data"]["id"]
            print(f"{ident}: bundle id {bid} created")

        have = {c["attributes"]["capabilityType"]
                for c in asc.call("GET", f"/bundleIds/{bid}/bundleIdCapabilities")["data"]}
        for cap in caps:
            if cap in have:
                print(f"  capability {cap} already enabled")
                continue
            asc.call("POST", "/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
                     "attributes": {"capabilityType": cap},
                     "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
            print(f"  capability {cap} enabled")

        name = f"VPN Bypass NE spike {stem.rsplit('-', 1)[-1]} DevID"
        profs = asc.call("GET", f"/bundleIds/{bid}/profiles")["data"]
        prof = next((p for p in profs if p["attributes"]["name"] == name
                     and p["attributes"]["profileState"] == "ACTIVE"
                     and p["attributes"]["profileType"] == "MAC_APP_DIRECT"), None)
        if prof:
            certs = asc.call("GET", f"/profiles/{prof['id']}/certificates")["data"]
            if cert_id not in [c["id"] for c in certs]:
                sys.exit(f"error: profile {prof['id']} exists under {name} but with another certificate; delete it first")
            prof = asc.call("GET", f"/profiles/{prof['id']}")["data"]
            print(f"  profile {prof['id']} reused ({prof['attributes']['profileState']})")
        else:
            r = asc.call("POST", "/profiles", {"data": {"type": "profiles",
                         "attributes": {"name": name, "profileType": "MAC_APP_DIRECT"},
                         "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}},
                                           "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
            if r is None:
                continue
            prof = r["data"]
            print(f"  profile {prof['id']} created ({prof['attributes']['profileState']})")
        path = os.path.join(out, f"{stem}.provisionprofile")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64decode(prof["attributes"]["profileContent"]))
        os.chmod(path, 0o600)
        print(f"  wrote {path} (expires {prof['attributes']['expirationDate']})")


if __name__ == "__main__":
    main()
