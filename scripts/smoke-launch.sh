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
# It is also the release's launch gate. release.yml runs it on the signed, notarized app: the
# app and its per-app routing extension carry Network Extension entitlements, and AMFI kills a
# binary whose embedded provisioning profile does not cover them, at exec, before any of our code
# runs (exit 137). That would take the whole app down on every user's Mac, so the gate also execs
# the extension's binary and fails if AMFI killed it. Proven on a GitHub macOS runner: a wrong
# profile and no profile were killed, the right one ran.
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

# The extension normally runs only when sysextd starts it, so exec it by hand: AMFI judges its
# signature and profile at exec. Outside sysextd it may exit or wait; only SIGKILL is a failure.
ext_bin="$app/Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension/Contents/MacOS/com.geiserx.vpn-bypass.proxy"
if [ -e "$ext_bin" ]; then
  "$ext_bin" >/dev/null 2>&1 &
  ext_pid=$!
  sleep 3
  if kill -0 "$ext_pid" 2>/dev/null; then
    kill -TERM "$ext_pid" 2>/dev/null || true
    wait "$ext_pid" 2>/dev/null || true
    echo "Extension binary started and kept running."
  else
    ext_status=0
    wait "$ext_pid" || ext_status=$?
    [ "$ext_status" -ne 137 ] \
      || { echo "::error::the extension was killed at exec (SIGKILL): AMFI refused its signature or provisioning profile"; exit 1; }
    echo "Extension binary started and exited with status $ext_status (not killed)."
  fi
fi

sock="$HOME/Library/Application Support/VPNBypass/control.sock"
applog="$HOME/Library/Logs/VPNBypass/vpnbypass.log"
rm -f "$sock"
# Measure the log instead of deleting it, so a run on a developer's Mac keeps their history
# and an old log can't stand in for this launch's output.
log_before=$(stat -f %z "$applog" 2>/dev/null || echo 0)
out=$(mktemp)
"$bin" >"$out" 2>&1 &
pid=$!
trap 'kill -KILL "$pid" 2>/dev/null || true' EXIT

fail() {
  echo "::error::$1"
  echo "--- app stdout/stderr ---"; cat "$out"
  echo "--- app log (this launch) ---"; tail -c +"$((log_before + 1))" "$applog" 2>/dev/null || echo "(no log file)"
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
  if ! kill -0 "$pid" 2>/dev/null; then
    status=0
    wait "$pid" || status=$?
    [ "$status" -ne 137 ] || fail "the app was killed at exec (SIGKILL): AMFI refused its signature or provisioning profile"
    fail "the app exited during launch (status $status)"
  fi
  if [ -S "$sock" ] && connect 2>/dev/null; then up=1; break; fi
  sleep 1
done
[ -n "$up" ] || fail "the control socket did not accept a connection within 60 s"
echo "Control socket is up."

sleep 15
kill -0 "$pid" 2>/dev/null || fail "the app exited within 15 s of launching"
log_after=$(stat -f %z "$applog" 2>/dev/null || echo 0)
[ "$log_after" -gt "$log_before" ] || fail "the app wrote nothing to $applog"
# The service catalogue ships as files in Contents/Resources/catalogue; a bundle without
# them launches fine but offers no services, and says so in the log.
if tail -c +"$((log_before + 1))" "$applog" | grep -q "Service catalogue:"; then
  fail "the app could not read its service catalogue"
fi
echo "--- app log (this launch) ---"; tail -c +"$((log_before + 1))" "$applog"
echo "Smoke launch passed: VPN Bypass $version launched, opened its control socket and kept running."
