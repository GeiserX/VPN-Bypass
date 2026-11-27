#!/usr/bin/env bash
# Measure what a large /etc/hosts section costs mDNSResponder, before blocklists depend on it.
#
#   sudo scripts/measure-hosts.sh [--control] [--orig FILE --orig-sha SHA256] [SIZE ...]
#
# Default sizes: 50000 100000 200000. For each size it runs two cases: with the flush the
# helper does after every hosts write (dscacheutil -flushcache; killall -HUP mDNSResponder)
# and without it. Each case:
#   1. writes the original file plus a section of SIZE synthetic names, one per line
#      ("0.0.0.0 nNNNNNNN.vpnb-measure.invalid"), with an atomic rename, mode 0644;
#   2. while it loads, resolves a fresh unlisted name (a random label under PROBE_DOMAIN,
#      default iana.org, which answers NXDOMAIN) and a real name (REAL_NAME, default
#      apple.com) through getaddrinfo every 50 ms, from 2 s before the rename until a listed
#      name answers 0.0.0.0, plus 10 s;
#   3. writes the same section plus one more name, as an unrelated small hosts write would
#      while a list is in place, and runs the same loop until that name answers;
#   4. puts the original file back with an atomic rename and runs the same loop until the
#      listed name stops answering 0.0.0.0, plus 10 s.
# It reports the longest lookup, the longest gap between two answers, the count of lookups
# slower than 500 ms, and the mDNSResponder memory (RSS) at each step. One JSON line per case.
#
# A case FAILS (exit 1) when the listed name (or the added one) never answers 0.0.0.0, when
# the listed name never stops answering after removal, or when the real name fails to resolve even once. --control writes
# every row of the section commented out, so the listed name can never answer 0.0.0.0: that
# run must fail, which proves the check can fail.
#
# Safety: it runs only as root, only writes synthetic names under vpnb-measure.invalid, and
# refuses to start unless /etc/hosts matches the saved original. Without --orig it saves the
# current file first. A trap puts the original back with its owner and mode on any exit,
# checks the sha256, flushes the caches and checks that REAL_NAME resolves. It kills nothing:
# mDNSResponder gives the memory it grew back only over minutes, not when the section goes.
# Run it on a spare Mac, never one whose DNS someone depends on during the run.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }

control=0
orig=""
orig_sha=""
sizes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --control) control=1 ;;
    --orig) orig="$2"; shift ;;
    --orig-sha) orig_sha="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) sizes+=("$1") ;;
  esac
  shift
done
[ ${#sizes[@]} -gt 0 ] || sizes=(50000 100000 200000)

HOSTS=/private/etc/hosts
TMP=/private/etc/hosts.vpnb-measure.tmp
PY="${PYTHON:-/usr/bin/python3}"
work="$(mktemp -d /tmp/vpnb-measure.XXXXXX)"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -z "$orig" ]; then
  orig="$work/hosts.orig"
  cp -p "$HOSTS" "$orig"
  orig_sha="$(sha "$orig")"
fi
[ -n "$orig_sha" ] || { echo "--orig needs --orig-sha" >&2; exit 2; }
[ "$(sha "$orig")" = "$orig_sha" ] || { echo "saved original does not match its sha256" >&2; exit 2; }
[ "$(sha "$HOSTS")" = "$orig_sha" ] || { echo "/etc/hosts is not the saved original; refusing" >&2; exit 2; }
owner="$(stat -f '%u:%g' "$HOSTS")"
mode="$(stat -f '%Lp' "$HOSTS")"
echo "original sha256=$orig_sha owner=$owner mode=$mode"

restore() {
  rc=$?
  trap - EXIT INT TERM HUP
  if [ "$(sha "$HOSTS")" != "$orig_sha" ]; then
    cp "$orig" "$TMP" && chown "$owner" "$TMP" && chmod "$mode" "$TMP" && mv -f "$TMP" "$HOSTS"
  fi
  chown "$owner" "$HOSTS"; chmod "$mode" "$HOSTS"
  rm -f "$TMP"
  dscacheutil -flushcache; killall -HUP mDNSResponder || true
  sleep 1
  now="$(sha "$HOSTS")"
  real_ok=NO
  for _ in 1 2 3 4 5; do
    if dscacheutil -q host -a name "${REAL_NAME:-apple.com}" | grep -q '^ip_address'; then real_ok=YES; break; fi
    sleep 1
  done
  echo "RESTORED rc=$rc sha_match=$([ "$now" = "$orig_sha" ] && echo YES || echo NO)" \
       "owner_mode=$(stat -f '%u:%g %Lp' "$HOSTS") test_lines=$(grep -c 'vpnb-measure' "$HOSTS" || true)" \
       "${REAL_NAME:-apple.com}_resolves=$real_ok"
  rm -rf "$work"
  [ "$now" = "$orig_sha" ] && [ "$real_ok" = YES ] || exit 3
  exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

ORIG="$orig" HOSTS="$HOSTS" TMP="$TMP" WORK="$work" CONTROL="$control" \
  "$PY" -I - "${sizes[@]}" <<'PY'
import json, os, random, socket, string, subprocess, sys, threading, time

ORIG, HOSTS, TMP, WORK = (os.environ[k] for k in ("ORIG", "HOSTS", "TMP", "WORK"))
CONTROL = os.environ["CONTROL"] == "1"
PROBE_DOMAIN = os.environ.get("PROBE_DOMAIN", "iana.org")
REAL = os.environ.get("REAL_NAME", "apple.com")
DOM = "vpnb-measure.invalid"
STEP, SLOW, TAIL = 0.05, 0.5, 10.0
TIMEOUT = 25.0 if CONTROL else 120.0
pc = time.perf_counter
failed = False


def sh(*a):
    return subprocess.run(list(a), capture_output=True, text=True, timeout=60)


def flush():
    sh("dscacheutil", "-flushcache")
    sh("killall", "-HUP", "mDNSResponder")


def mdns_pid():
    return int(sh("pgrep", "-x", "mDNSResponder").stdout.split()[0])


def rss_mb():
    pid = str(mdns_pid())
    return round(int(sh("ps", "-o", "rss=", "-p", pid).stdout) / 1024)


def gai(name):
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM)})
    except socket.gaierror:
        return None


def fresh():
    return "".join(random.choices(string.ascii_lowercase, k=12)) + "." + PROBE_DOMAIN


def install(path):
    """Atomic rename of path into place, mode 0644 as the helper writes it."""
    sh("cp", path, TMP)
    os.chmod(TMP, 0o644)
    os.rename(TMP, HOSTS)


class Prober(threading.Thread):
    """Resolves one kind of name every STEP seconds and records (start, duration, answer)."""

    def __init__(self, kind, name_fn):
        super().__init__(daemon=True)
        self.kind, self.name_fn, self.rows, self.stop = kind, name_fn, [], threading.Event()

    def run(self):
        while not self.stop.is_set():
            t = pc(); r = gai(self.name_fn()); self.rows.append((t, pc() - t, r))
            self.stop.wait(STEP)

    def summary(self, t0):
        durs = [d for _, d, _ in self.rows]
        ends = [t + d for t, d, _ in self.rows]
        gaps = [b - a for a, b in zip(ends, ends[1:])]
        return {"lookups": len(durs), "longest_ms": round(max(durs) * 1000),
                "longest_gap_ms": round(max(gaps) * 1000) if gaps else None,
                "over_500ms": sum(d > SLOW for d in durs),
                "worst_at_s": round(max(self.rows, key=lambda x: x[1])[0] - t0, 2),
                "failures": sum(r is None for _, _, r in self.rows)}


def window(change, listed, done_when):
    """Run the probers across change(); stop TAIL seconds after done_when(answer) holds."""
    probers = [Prober("unlisted", fresh), Prober("real", lambda: REAL)]
    for p in probers:
        p.start()
    time.sleep(2.0)
    t0 = pc(); change(); seen = None
    while pc() - t0 < TIMEOUT:
        if done_when(gai(listed)):
            seen = pc() - t0
            break
        time.sleep(STEP)
    rss_seen = rss_mb()
    time.sleep(TAIL)
    for p in probers:
        p.stop.set()
    for p in probers:
        p.join()
    out = {"effective_s": round(seen, 2) if seen is not None else None, "rss_mb_at_effect": rss_seen}
    for p in probers:
        out[p.kind] = p.summary(t0)
    return out, seen


def build(n, offset):
    path = os.path.join(WORK, f"hosts.{n}")
    orig = open(ORIG).read()
    with open(path, "w") as f:
        f.write(orig if orig.endswith("\n") else orig + "\n")
        f.write("# VPNB-MEASURE - START (synthetic names, safe to delete)\n")
        pre = "# 0.0.0.0 " if CONTROL else "0.0.0.0 "
        for i in range(n):
            f.write(f"{pre}n{offset + i:07d}.{DOM}\n")
        f.write("# VPNB-MEASURE - END\n")
    return path, f"n{offset + n - 1:07d}.{DOM}"


def case(n, with_flush, offset):
    global failed
    path, listed = build(n, offset)
    flush(); time.sleep(3)
    R = {"names": n, "flush": with_flush, "control": CONTROL, "rss_mb_before": rss_mb(), "mdns_pid": mdns_pid()}

    def load():
        install(path)
        if with_flush:
            flush()

    def unload():
        install(ORIG)
        if with_flush:
            flush()

    # An unrelated small write while the section is in place (as when the app updates a
    # pinned name): the same section plus one more name, which must start answering.
    path2, extra = build(n + 1, offset)

    def rewrite():
        install(path2)
        if with_flush:
            flush()

    R["add"], seen = window(load, listed, lambda r: r == ["0.0.0.0"])
    R["rss_mb_after_add"] = rss_mb()
    R["rewrite"], again = window(rewrite, extra, lambda r: r == ["0.0.0.0"])
    R["remove"], gone = window(unload, listed, lambda r: r != ["0.0.0.0"])
    R["rss_mb_after_remove"] = rss_mb()
    if mdns_pid() != R["mdns_pid"]:
        R["mdns_pid_changed_to"] = mdns_pid()
    why = []
    if seen is None:
        why.append(f"listed name never answered 0.0.0.0 within {TIMEOUT:.0f} s")
    if again is None:
        why.append(f"the name added by the rewrite never answered 0.0.0.0 within {TIMEOUT:.0f} s")
    if gone is None:
        why.append(f"listed name still answered 0.0.0.0 {TIMEOUT:.0f} s after removal")
    for phase in ("add", "rewrite", "remove"):
        if R[phase]["real"]["failures"]:
            why.append(f"{REAL} failed to resolve {R[phase]['real']['failures']} times during {phase}")
    R["result"] = "FAIL: " + "; ".join(why) if why else "PASS"
    failed |= bool(why)
    print(json.dumps(R), flush=True)


# Baseline: the same probers for 10 s with no change, to show the noise floor.
probers = [Prober("unlisted", fresh), Prober("real", lambda: REAL)]
for p in probers:
    p.start()
t0 = pc(); time.sleep(10)
for p in probers:
    p.stop.set(); p.join()
print(json.dumps({"baseline": {p.kind: p.summary(t0) for p in probers}, "rss_mb": rss_mb()}), flush=True)

run = 0
for n in map(int, sys.argv[1:]):
    for with_flush in (True, False):
        run += 1
        case(n, with_flush, run * 1_000_000)
sys.exit(1 if failed else 0)
PY
