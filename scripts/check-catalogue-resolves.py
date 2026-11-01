#!/usr/bin/env python3
"""Flag catalogue domains that stopped resolving.

Reads every file in Sources/VPNBypassCore/Resources/catalogue/ and asks public DNS
about each domain:

- a plain name (``example.com``) must have an IPv4 address;
- a wildcard (``*.example.com``) must have a suffix that exists: NXDOMAIN means the
  site is gone. A suffix with no address of its own is fine, its hosts are what the
  wildcard routes.

A name counts as dead only when two resolvers (1.1.1.1 and 8.8.8.8) both say so, each
asked up to three times, so one resolver's bad minute does not flag a site. A timeout
or SERVFAIL is not an answer and never flags anything.

The catalogue is best effort (see its README): this runs on a schedule, not on every
pull request, and a flagged name is a reason to look, not a release blocker.

Needs dig. Exits 1 and lists the dead names when there are any.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

CATALOGUE = Path(__file__).resolve().parent.parent / "Sources/VPNBypassCore/Resources/catalogue"
RESOLVERS = ["1.1.1.1", "8.8.8.8"]
ATTEMPTS = 3


def ask(name: str, resolver: str) -> tuple[str, list[str]] | None:
    """The status and the IPv4 answers for name, or None when no answer came."""
    try:
        out = subprocess.run(
            ["dig", f"@{resolver}", "+time=3", "+tries=1", "+noall", "+comments", "+answer", name, "A"],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except subprocess.TimeoutExpired:
        return None
    status = None
    addresses = []
    for line in out.splitlines():
        if "status:" in line:
            status = line.split("status:")[1].split(",")[0].strip()
        elif not line.startswith(";"):
            parts = line.split()
            if len(parts) >= 5 and parts[3] == "A":
                addresses.append(parts[4])
    # Only NOERROR and NXDOMAIN are answers; SERVFAIL, REFUSED, FORMERR and the rest are not.
    if status not in ("NOERROR", "NXDOMAIN"):
        return None
    return status, addresses


def why_dead(domain: str) -> str | None:
    """Why domain looks dead to every resolver, or None when one resolver finds it alive
    or none gives an answer."""
    wildcard = domain.startswith("*.")
    name = domain[2:] if wildcard else domain
    reasons = []
    for resolver in RESOLVERS:
        answer = None
        for attempt in range(ATTEMPTS):
            answer = ask(name, resolver)
            if answer is not None:
                break
            time.sleep(1 + attempt)
        if answer is None:
            return None
        status, addresses = answer
        if status == "NXDOMAIN":
            reasons.append("does not exist")
        elif not wildcard and not addresses:
            reasons.append(f"has no IPv4 address ({status})")
        else:
            return None
    return reasons[0]


def main() -> int:
    if subprocess.run(["which", "dig"], capture_output=True).returncode != 0:
        print("dig is not installed", file=sys.stderr)
        return 2
    dead = []
    checked = 0
    for path in sorted(CATALOGUE.glob("*.json")):
        for service in json.loads(path.read_text())["services"]:
            for domain in service["domains"]:
                checked += 1
                reason = why_dead(domain)
                if reason:
                    dead.append(f"{path.name}: {service['id']}: {domain} {reason}")
    print(f"checked {checked} domains")
    for line in dead:
        print(line)
    return 1 if dead else 0


if __name__ == "__main__":
    sys.exit(main())
