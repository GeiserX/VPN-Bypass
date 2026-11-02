#!/usr/bin/env python3
"""Rewrite Sources/VPNBypassCore/CDNRangeList.swift from the CDNs' published IPv4 ranges.

The Domains page says when a listed name resolved to one of these addresses: routing is per
IP, so every other site served from that address takes the same route. The list is never
edited by hand; run this script and commit the file it writes.

Sources, each the CDN's own published list:
    Cloudflare  https://www.cloudflare.com/ips-v4
    Fastly      https://api.fastly.com/public-ip-list               ("addresses")
    CloudFront  https://ip-ranges.amazonaws.com/ip-ranges.json      (service CLOUDFRONT,
                without CLOUDFRONT_ORIGIN_FACING, which CloudFront uses to reach origins and
                no lookup returns)

Akamai, Google and others publish no list of their CDN edge ranges, so their addresses are
not recognised. IPv6 is left out: the app routes IPv4 only.

Usage:
    scripts/update-cdn-ranges.py           # fetch, write the Swift file
    scripts/update-cdn-ranges.py --check   # exit 1 when the committed file is out of date

Fails when a source returns no ranges, so a broken download never empties the list.
"""

import datetime
import ipaddress
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "VPNBypassCore" / "CDNRangeList.swift"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "VPN-Bypass update-cdn-ranges"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode()


def cloudflare():
    return [line.strip() for line in fetch("https://www.cloudflare.com/ips-v4").splitlines() if line.strip()]


def fastly():
    return json.loads(fetch("https://api.fastly.com/public-ip-list"))["addresses"]


def cloudfront():
    data = json.loads(fetch("https://ip-ranges.amazonaws.com/ip-ranges.json"))
    edge = {p["ip_prefix"] for p in data["prefixes"] if p["service"] == "CLOUDFRONT"}
    origin = {p["ip_prefix"] for p in data["prefixes"] if p["service"] == "CLOUDFRONT_ORIGIN_FACING"}
    return sorted(edge - origin)


def collapse(name, cidrs):
    nets = [ipaddress.IPv4Network(c, strict=True) for c in cidrs]
    if not nets:
        sys.exit(f"{name}: the published list is empty; keeping the committed file")
    return list(ipaddress.collapse_addresses(nets))


def render(lists):
    today = datetime.date.today().isoformat()
    rows = []
    for cdn, nets in lists:
        for net in nets:
            rows.append((int(net.network_address), cdn, str(net)))
    rows.sort()
    for (a, cdn_a, cidr_a), (b, cdn_b, cidr_b) in zip(rows, rows[1:]):
        if ipaddress.IPv4Network(cidr_a).overlaps(ipaddress.IPv4Network(cidr_b)):
            sys.exit(f"{cidr_a} ({cdn_a}) overlaps {cidr_b} ({cdn_b})")
    body = "\n".join(f'        ("{cdn}", "{cidr}"),' for _, cdn, cidr in rows)
    counts = ", ".join(f"{cdn} {len(nets)}" for cdn, nets in lists)
    return f"""// CDNRangeList.swift
// Written by scripts/update-cdn-ranges.py on {today}; do not edit by hand, run the script.
// The CDNs' published IPv4 ranges ({counts}), sorted by start address, none overlapping.

enum CDNRangeList {{
    static let refreshed = "{today}"

    static let ranges: [(cdn: String, cidr: String)] = [
{body}
    ]
}}
"""


def main():
    lists = [("Cloudflare", collapse("Cloudflare", cloudflare())),
             ("Fastly", collapse("Fastly", fastly())),
             ("CloudFront", collapse("CloudFront", cloudfront()))]
    text = render(lists)
    if "--check" in sys.argv[1:]:
        old = OUT.read_text() if OUT.exists() else ""
        strip = lambda s: [l for l in s.splitlines() if "update-cdn-ranges.py on" not in l and "refreshed =" not in l]
        if strip(old) != strip(text):
            sys.exit(f"{OUT.relative_to(ROOT)} is out of date; run scripts/update-cdn-ranges.py")
        print("CDN ranges are current")
        return
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
