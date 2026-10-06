#!/usr/bin/env bash
# Launch a built VPN Bypass.app and prove it comes up: it launches, opens its control
# socket, writes its log, and is still running 15 s later. Also checks the bundle's
# version stamp and that the bundled vpnb CLI runs.
#
#   scripts/smoke-launch.sh "VPN Bypass.app"
#
# CI runs it on every pull request and every push to main (job "build and launch app"),
# and release.yml refuses to publish a commit where that job is not green.
#
# What it cannot check: anything that needs the main thread after launch. On a machine
# without the privileged helper (every CI runner) the app asks for an admin password to
# install it, and that prompt holds the main thread, so `vpnb status` gets no answer and
# SIGTERM's teardown never runs. The script therefore stops the app with SIGKILL. Run it
# with no other VPN Bypass running: a second instance exits at once by design.
set -euo pipefail

app="${1:?usage: $0 PATH/TO/VPN\ Bypass.app}"
bin="$app/Contents/MacOS/VPNBypass"
cli="$app/Contents/MacOS/vpnb"
for f in "$bin" "$cli"; do
  [ -x "$f" ] || { echo "::error::$f is missing or not executable"; exit 1; }
done
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "::error::Info.plist version is '$version', not X.Y.Z"; exit 1; }
"$cli" --help >/dev/null || { echo "::error::vpnb --help failed"; exit 1; }

sock="$HOME/Library/Application Support/VPNBypass/control.sock"
applog="$HOME/Library/Logs/VPNBypass/vpnbypass.log"
rm -f "$sock"
out=$(mktemp)
"$bin" >"$out" 2>&1 &
pid=$!
trap 'kill -KILL "$pid" 2>/dev/null || true' EXIT

fail() {
  echo "::error::$1"
  echo "--- app stdout/stderr ---"; cat "$out"
  echo "--- app log ---"; cat "$applog" 2>/dev/null || echo "(no log file)"
  exit 1
}

# The control socket opens in applicationDidFinishLaunching, so a socket that accepts a
# connection means the app finished launching.
connect() {
  python3 - "$sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
s.connect(sys.argv[1])
PY
}
up=""
for _ in $(seq 1 60); do
  kill -0 "$pid" 2>/dev/null || fail "the app exited during launch"
  if [ -S "$sock" ] && connect 2>/dev/null; then up=1; break; fi
  sleep 1
done
[ -n "$up" ] || fail "the control socket did not accept a connection within 60 s"
echo "Control socket is up."

sleep 15
kill -0 "$pid" 2>/dev/null || fail "the app exited within 15 s of launching"
[ -s "$applog" ] || fail "the app wrote nothing to $applog"
echo "--- app log ---"; cat "$applog"
echo "Smoke launch passed: VPN Bypass $version launched, opened its control socket and kept running."
