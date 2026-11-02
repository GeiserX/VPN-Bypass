# NE proxy spike

A throwaway test build for `docs/design/NETWORK-EXTENSION-DESIGN.md` (stage 5, the spike). It is its own
Swift package: nothing here is linked into, or shipped with, VPN Bypass.

It answers four questions only a live Mac can answer:

1. Does a flow the extension claims and re-emits on the physical interface leave **outside** a
   connected GlobalProtect tunnel?
2. Does matching **by app** (signing id) and **by host name** work?
3. Does every flow that is **not** matched pass through untouched, the VPN client's own included?
4. What happens to open and new connections when the extension is **paused, stopped or killed**?

## What is in the bundle

```
VPN Bypass NE Spike.app                      com.geiserx.vpn-bypass.spike
  Contents/MacOS/VPNBypassNESpike            the window with the buttons
  Contents/MacOS/spike-fetch                 test client, signed com.geiserx.vpn-bypass.spike.fetch
  Contents/embedded.provisionprofile
  Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.spike.proxy.systemextension
    Contents/MacOS/com.geiserx.vpn-bypass.spike.proxy   NETransparentProxyProvider (class FlowProxy)
    Contents/embedded.provisionprofile
```

How it behaves:

- **Nothing starts at launch.** Every activation, start, push and stop is a button.
- **Include scope** is chosen at start. `port:80` sends the extension only TCP to remote port 80, so a
  VPN client's own TLS connections (443) are not even offered to it. `all` is the v1 design: every
  outbound TCP flow except loopback, private, link-local, multicast and 100.64/10.
- **A start by the OS is always `port:80`.** Only the app's **2. Start proxy** passes a scope. If macOS
  starts the extension itself with no options, it comes up on `port:80`, never `all`, whatever scope
  ran before. The status pane shows the scope in force (`scope port:80` or `scope all`).
- **After a crash or `kill -9` the proxy stays off.** On the mini (macOS 26.6.1, Part A, A3) macOS did
  not restart the extension: about 5 s after the kill it logged "Extension exit timer expired", the
  session went to disconnected ("Plugin failed"), and it stayed off until the next start. Traffic
  then goes the way it would without the spike. During those 5 s, new flows inside the include scope
  hang and claimed flows die.
- **No policy, no claims.** Until you press *Push policy*, and whenever the app has not refreshed the
  policy for 2 minutes (the lease; the app re-sends it every 30 s), the extension declines every flow.
- **What it claims:** a TCP flow from an app in the *Apps* list (bundle id, exact or on a dot boundary,
  or a bare executable name), or a connect-by-name flow to a host in *Host names* (exact or a
  subdomain). Never: our own binaries, a few Apple daemons, anything signed by Palo Alto (team
  `PXPZ95SK77`) or Tailscale (`W5364U7YZB`), a socket the app bound itself, IPv6.
- **How it re-emits:** a new `nw_connection` with the flow's metadata, IPv4 only, required to use the
  physical interface (the most preferred Wi-Fi or Ethernet one, or the one typed in *Egress interface*).
- **What it logs:** fixed events with numbers only, to the macOS unified log (which macOS keeps on
  disk by its own rules). No app ids, no addresses, no host names; no log file of its own. The window shows counters (`claimed.app`, `claimed.hostname`, `declined.<reason>`,
  `egressOnPolicyInterface`, `activeFlows`, bytes, `leaseExpiries`).

## Build, sign, verify (already done for the current artifact)

Profiles live outside the repo, in `~/DevIDApp-personal-profiles/` (mode 600). They were minted with
`scripts/asc-profiles.py` (bundle ids `com.geiserx.vpn-bypass.spike` and `.spike.proxy`, capabilities
Network Extensions and System Extension, `MAC_APP_DIRECT` against the Developer ID G2 certificate).

```sh
# build Mac (universal, unsigned; checks SYSX, NEProviderClasses class present, universal, system libs only)
scripts/build.sh
swift test
# Mac with the Developer ID identity: inside-out signing, profile checks, notarize, staple, spctl
SIGN_IDENTITY=<cert SHA-1> PROFILE_DIR=~/DevIDApp-personal-profiles NOTARY_PROFILE=<profile> \
  scripts/sign.sh "build/VPN Bypass NE Spike.app"
```

## Order of the live tests

The design asks for the risky questions (does a start or stop close flows it does not claim; what a
crash does) to be answered first on the Mac mini, where a dropped tunnel costs nothing. So:

- **Part A, the mini:** activation, matching, L1 (start/stop vs. unrelated TCP, with Tailscale's own
  connections standing in for the VPN client's), L8 (kill -9).
- **Part B, the MacBook with GlobalProtect connected:** scope `port:80` first. Scope `all` only if
  Part A showed that starting and stopping the proxy leaves unmatched connections alone.

**Which steps run with scope `all`, and their gate.** Only three: the second pass of A2 (on the mini),
B4, and B3 if you choose to run it under `all`. **Gate: no step with scope `all` runs on the MacBook
until A2 with scope `all` has passed on the mini** (download, `ssh` session and Tailscale's
connections all survived the start and the stop). That covers B4 and any B3 step under `all`,
B3.4 `kill -9` included. Every other step runs with `port:80`. A `kill -9` leaves the proxy off (see
above), so after B3.4 run **2. Start proxy** and **3. Push policy** again before the next step.

Rules for both parts: never restart, reconnect or reconfigure GlobalProtect or any VPN to make a test
work. If GlobalProtect drops at any point: press **Turn off** in the spike, write down the time, then
reconnect GlobalProtect yourself the way you always do.

## Approve it (both Macs, owner only)

1. Copy the app to `/Applications` (system extensions only activate from there):
   `ditto "build/VPN Bypass NE Spike.app" "/Applications/VPN Bypass NE Spike.app"`
2. Open it. A window appears; nothing is active yet.
3. Click **1. Activate extension**. macOS says the system extension was blocked.
4. Turn it on in System Settings and enter your password. *Expected; confirm during the test:* the
   switch is under General > Login Items & Extensions > Network Extensions, named
   **VPN Bypass NE Spike**. These menu paths were not seen live on macOS 26 or 27. If it is not
   there, type `extension` in the System Settings search field, or open the alert's own
   *Open System Settings* button; write down where it really was.
5. Check: `systemextensionsctl list | grep spike` shows `[activated enabled]`.
6. In the app pick the scope, click **2. Start proxy**. The first time macOS asks to allow the proxy
   configuration (*expected; confirm during the test:* "VPN Bypass NE Spike would like to add proxy
   configurations"): **Allow**. Note the real wording.
7. The status pane says `proxy: connected, configuration enabled` and shows the extension pid.

## Drive it from a shell

The app binary takes commands, so everything except the owner's two approvals runs over `ssh`
without a click. Each command calls the same `Controller` method as its button, prints what the
window would log plus the status pane, and exits. Run it as the console user from the installed
bundle (the configuration belongs to that user's app):

```sh
B="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/VPNBypassNESpike"
spike() { sudo launchctl asuser "$(id -u sergio)" sudo -u sergio "$B" "$@"; }

spike status                    # proxy state, last disconnect error, the extension's counters
spike activate                  # 1. Activate extension; exit 3 = the owner must approve it
spike start --scope port:80     # 2. Start proxy (port:80 or all); waits up to 20 s for "connected"
spike push --apps com.geiserx.vpn-bypass.spike.fetch --hosts ipv4.icanhazip.com [--iface en0] [--hold]
spike pause [--hold]            # empty policy
spike stop-session
spike turn-off
spike remove                    # configuration, then the extension; macOS may ask for a password
```

Exit codes: 0 ok, 1 failed, 2 usage, 3 needs the owner's approval. A push without `--hold` leaves a
lease that ends 2 minutes later (the process exits, so nothing re-sends it); `--hold` keeps the 30 s
heartbeat going until the process gets SIGINT or SIGTERM. Any first argument that is not a flag runs
the command line (an unknown one prints the usage); no arguments opens the window.

Drive it from one place at a time: the window and a `--hold` process each re-send their own last
policy every 30 s, so a `pause` from the shell lasts only until an open window's next heartbeat.

`status` prints macOS's last disconnect error for the session, which is where a refused
`setTunnelNetworkSettings` shows up (`Either a non-wildcard port or a non-wildcard address must be
specified` was the 0.1.1 start failure: an excluded rule on 0.0.0.0/8 with port 0).

## Part A: the Mac mini (no GlobalProtect)

**What Part A can and cannot answer.** The mini runs with SIP off and the boot argument
`amfi_get_out_of_my_way=0x1`. AMFI there does not enforce signatures or provisioning profiles, so
Part A tests how flows behave (matching, start, stop, kill) and says nothing about whether macOS
accepts the signed bundle and its profiles. That question (L0) was answered on the MacBook, where
SIP and AMFI are on: a copy without its embedded profile is killed at launch (exit 137), the signed
copy runs.

**Getting the signed app onto the mini.** Copy the notarized, stapled bundle from the MacBook's build
directory with `ditto`, which keeps signatures, extended attributes and the staple intact; then
check it on the mini before installing:

```sh
# on the MacBook, in spikes/ne-proxy
ditto -c -k --keepParent "build/VPN Bypass NE Spike.app" /tmp/ne-spike.zip
scp /tmp/ne-spike.zip <mini>:/tmp/ && rm /tmp/ne-spike.zip
# on the mini
sudo ditto -x -k /tmp/ne-spike.zip /Applications/ && rm /tmp/ne-spike.zip
codesign --verify --deep --strict --verbose=2 "/Applications/VPN Bypass NE Spike.app"
xcrun stapler validate "/Applications/VPN Bypass NE Spike.app"
```

Do not copy it with plain `cp -R`, `scp -r` or `rsync` without extended attributes: a bundle whose
seal breaks on the way fails `codesign --verify`.

```sh
F="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/spike-fetch"
```

**A1, activation and matching.** Scope `port:80`, Apps `com.geiserx.vpn-bypass.spike.fetch`, Host
names `ipv4.icanhazip.com`, click **3. Push policy**.

| Command | Expect |
|---|---|
| `"$F" http://api4.ipify.org` | 200, `claimed.app` +1, `egressOnPolicyInterface` +1 |
| `curl -s http://api4.ipify.org` | answer, `declined.noMatch` +1 |
| `nscurl http://ipv4.icanhazip.com` | answer, `claimed.hostname` +1 (NSURLSession connects by name) |
| `curl -s http://ipv4.icanhazip.com` | answer, `claimed.hostname` +1 on macOS 26.6.1 (Part A: macOS fills in the flow's host name even for clients that resolve it themselves; the design expected `declined.noMatch`) |

Without a VPN all of them show the same public IP; here the counters are the result.

**A2, L1: does a start or a stop close flows it does not claim?** Click **Pause** (empty policy) first,
so nothing is claimed. Before each start or stop, open:

```sh
ssh <another box>                                        # an interactive session, outside port 80
curl -o /dev/null http://ipv4.download.thinkbroadband.com/1GB.zip   # a long port-80 download (matched by the include rule)
sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED | grep -i tailscale > /tmp/ts-before.txt
```

Then **Turn off**, **2. Start proxy**, wait 30 s, **Stop session**, and after each step note: did the
download stop, did the `ssh` session die, are Tailscale's connections (`lsof` again, compare the
local ports) the same ones? Do it once with scope `port:80` and once with scope `all`. Repeat the same
period once without touching the spike, as the control.

**A3, L8: kill -9.** With the policy pushed and `"$F" --every 120 http://api4.ipify.org` running:

```sh
# the extension's own process: its executable under /Library/SystemExtensions, nothing else
# (pgrep -f also matches a `log stream` or `grep` naming the bundle id, and pgrep -x any process
# with the same executable name anywhere on disk)
pid=$(ps -axo pid=,comm= | awk '$2 ~ /^\/Library\/SystemExtensions\/[^ ]*\/com\.geiserx\.vpn-bypass\.spike\.proxy$/ {print $1}')
echo "$pid"                     # exactly one number; stop here if it is empty or more than one
sudo kill -9 "$pid"
```

Expected from Part A: about 5 s later macOS logs "Extension exit timer expired" and the session goes
to disconnected; the extension is not restarted, so the proxy stays off until the next start.

Watch the `spike-fetch` lines (do new requests fail, stall or go direct, and for how long), whether a
new extension pid appears, and whether Tailscale's connections survive.

## Part B: the MacBook with GlobalProtect connected

Before anything, in a terminal:

```sh
F="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/spike-fetch"
route -n get api4.ipify.org | grep interface      # must be a utun: the VPN carries this host
route -n get ipv4.icanhazip.com | grep interface  # same
curl -s http://api4.ipify.org; echo               # this is VPN_IP
```

If either host shows `en0`/`en8`, the VPN does not carry it (split tunnel, or VPN Bypass itself routes
it around the VPN): pick two hosts that answer with your IP and that the VPN carries, and use them below.
Your home IP (HOME_IP) is the one your router reports; do not disconnect the VPN to find it.

Keep these open in other terminals for the whole session:

```sh
# the spike's own events (numbers only)
log stream --style compact --predicate 'subsystem == "com.geiserx.vpn-bypass.spike.proxy"'
# GlobalProtect's view: look for Broken pipe, disconnect, reconnect, HIP
tail -F "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS.log"
# GlobalProtect's sockets, to compare before and after each start and stop
sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED | grep -i -E 'PanGP|GlobalProt' > /tmp/gp-before.txt
```

Apple's own NE logs (`log stream --predicate 'process == "nesessionmanager" OR process == "sysextd"'`)
help when activation or start fails; they are Apple's, not ours, and may name more than the spike does,
so do not paste them anywhere public.

**B1, egress outside the tunnel (question 1).** Scope `port:80`, Apps
`com.geiserx.vpn-bypass.spike.fetch`, Host names `ipv4.icanhazip.com`, **Start**, **Push policy**.

| Command | Matched by | Should show |
|---|---|---|
| `"$F" http://api4.ipify.org` | app | **HOME_IP** |
| `curl -s http://api4.ipify.org` | nothing | **VPN_IP** |
| `nscurl http://ipv4.icanhazip.com` | host name | **HOME_IP** |
| `curl -s http://ipv4.icanhazip.com` | host name (macOS fills in the name even though curl connects by IP, as Part A showed) | **HOME_IP** |
| `nscurl http://api4.ipify.org` | nothing | **VPN_IP** |

While a claimed download runs, see where its upstream socket lives:

```sh
"$F" --download http://ipv4.download.thinkbroadband.com/1GB.zip &
sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED -a -c com.geiserx   # the extension's socket: local address must be en0/en8's, not the utun's
ifconfig en0 | grep 'inet '; ifconfig | grep -A3 '^utun' | grep 'inet '
sudo tcpdump -ni en0 -c 20 tcp port 80                     # the download's packets on the physical interface
```

The status pane should show `egressOnPolicyInterface` rising and `egressOffPolicyInterface` at 0.

**B2, unmatched traffic untouched (question 3).** Use the Mac normally for 10 minutes with the policy
pushed: browsing, mail, chat. `declined.*` counters rise, `claimed.*` stay at what B1 made, and
GlobalProtect's log and `lsof` list show no change against `/tmp/gp-before.txt`.

**B3, stops (question 4).** With `"$F" --every 600 http://api4.ipify.org` and a claimed
`"$F" --download ...` running, one at a time, noting what each `spike-fetch` prints:

1. **Pause**: new requests should show VPN_IP; does the running download continue?
2. **Quit the app** (lease test): within 2 minutes new requests show VPN_IP and `leaseExpiries` is 1
   when you reopen it. Push again afterwards.
3. **Stop session**: does the claimed download die, do new requests go to VPN_IP at once, does
   GlobalProtect log anything?
4. **Kill -9** (Part A's A3 left Tailscale's connections alone):
   find `pid` and kill it with the commands in A3 (check it is exactly one number first), then watch
   as in A3. Expect about 5 s in which new flows inside the include scope hang (under `all` that
   includes GlobalProtect's new connections), then the proxy stays off. Under scope `all` this step
   also needs A2 with `all` passed. Start and push again afterwards.

**B4, scope `all`** (only if Part A's A2 showed unmatched connections survive a start and a stop with
scope `all`): **Turn off**, choose `all`, **Start**, **Push policy**, then repeat B1 with `https://`
URLs (`"$F" https://api4.ipify.org` and `curl -s https://api4.ipify.org`), and B2. Compare GlobalProtect's
sockets against `/tmp/gp-before.txt` right after the start.

Write down for each step: time (GlobalProtect logs local time), what each command printed (you can
replace the IPs with HOME_IP/VPN_IP), the counters, and any GlobalProtect log line.

## Remove it completely

1. In the app: **Remove completely**. It removes the proxy configuration (stops the proxy) and asks
   macOS to deactivate the extension; macOS may ask for your password.
2. Check: `systemextensionsctl list | grep spike` shows nothing, or
   `[terminated waiting to uninstall on reboot]`; System Settings no longer lists *VPN Bypass NE spike*
   under Network > Filters & Proxies (*expected path; confirm during the test*; VPN & Filters on older
   macOS; if it is not there, search System Settings for `Filters & Proxies` or `extension`).
3. Drag `/Applications/VPN Bypass NE Spike.app` to the Trash.

**If it misbehaves** (new connections hang, the app will not open), in this order, none of which touch
GlobalProtect:

1. System Settings > Network > Filters & Proxies (*expected path; confirm during the test*; VPN &
   Filters on older macOS; otherwise search System Settings for `Filters & Proxies`): switch
   **VPN Bypass NE spike** off. That stops the proxy and keeps the OS from restarting it.
2. System Settings > General > Login Items & Extensions > Network Extensions (*expected path*;
   otherwise search System Settings for `extension`): switch **VPN Bypass NE Spike** off.
3. Delete the app from `/Applications` in Finder; macOS removes its extension with it (after a reboot
   at the latest).
4. On the mini only (SIP is off there): `systemextensionsctl uninstall 624WUVM8B4 com.geiserx.vpn-bypass.spike.proxy`.

Do not `kill -9` the extension to stop it: that leaves the configuration enabled with a dead
session, and new flows hang for about 5 s first. Use **Turn off** (or `spike turn-off`).

## Rebuilding

```sh
rsync -a --delete --exclude .build --exclude build spikes/ne-proxy/ <build mac>:<scratch>/ne-proxy/
ssh <build mac> 'cd <scratch>/ne-proxy && scripts/build.sh && swift test'
rsync -a "<build mac>:<scratch>/ne-proxy/build/VPN Bypass NE Spike.app" spikes/ne-proxy/build/
# then scripts/sign.sh as above
```

Bump `CFBundleVersion` and `CFBundleShortVersionString` in both `bundle/*.plist` before installing a
new build over an activated one: macOS replaces an extension only when its version changes. Then
`spike activate` replaces it without a new approval (same team, higher version: "replacing extension
0.1.3 with 0.1.4", no prompt on the mini). The replacement ends the running session (`status` shows
`NEAgentErrorDomain error 2`), so run `spike start` and `spike push` again.
