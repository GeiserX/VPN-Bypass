#!/usr/bin/env bash
# Launch a built VPN Bypass.app and prove it comes up: the app process starts, opens its
# control socket, answers `vpnb status` with the version stamped into the bundle, is still
# running a few seconds later, and quits on SIGTERM.
#
#   scripts/smoke-launch.sh "VPN Bypass.app"
#
# CI runs it on every pull request and every push to main (job "build and launch app"),
# and release.yml refuses to publish a commit where that job is not green. Run it on a
# machine with no other VPN Bypass running: a second instance exits at once by design.
set -euo pipefail

app="${1:?usage: $0 PATH/TO/VPN\ Bypass.app}"
bin="$app/Contents/MacOS/VPNBypass"
cli="$app/Contents/MacOS/vpnb"
for f in "$bin" "$cli"; do
  [ -x "$f" ] || { echo "::error::$f is missing or not executable"; exit 1; }
done
expected=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ -n "$expected" ] || { echo "::error::Info.plist has no CFBundleShortVersionString"; exit 1; }

log=$(mktemp)
"$bin" >"$log" 2>&1 &
pid=$!
cleanup() { kill -KILL "$pid" 2>/dev/null || true; }
trap cleanup EXIT

fail() {
  echo "::error::$1"
  echo "--- app output ---"
  cat "$log"
  exit 1
}

# The control socket starts in applicationDidFinishLaunching, before any helper or route
# work, so `vpnb status` answering means the app finished launching.
status=""
for _ in $(seq 1 90); do
  kill -0 "$pid" 2>/dev/null || fail "the app exited during launch"
  if status=$("$cli" status 2>&1); then break; fi
  status=""
  sleep 1
done
[ -n "$status" ] || fail "the app did not answer vpnb status within 90 s"
echo "$status"
echo "$status" | grep -q "app: $expected" \
  || fail "vpnb status does not report app version $expected"

# Still alive after the startup work (config load, helper check, VPN detection) has run.
sleep 10
kill -0 "$pid" 2>/dev/null || fail "the app exited within 10 s of launching"

# A clean quit: SIGTERM runs the same teardown as Quit and exits on its own.
kill -TERM "$pid"
for _ in $(seq 1 30); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill -0 "$pid" 2>/dev/null && fail "the app did not exit within 30 s of SIGTERM"
wait "$pid" 2>/dev/null || true
trap - EXIT
echo "Smoke launch passed: app $expected started, answered vpnb status and quit on SIGTERM."
