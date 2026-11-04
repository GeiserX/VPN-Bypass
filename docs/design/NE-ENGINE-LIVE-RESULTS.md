# Per-app routing: live results on the Mac mini (step 5)

What the extension of step 5 did on a real Mac with a full-tunnel VPN connected. It answers L1, L8,
L9, L13 and the spike's B2 and B3.2 from `NETWORK-EXTENSION-DESIGN.md`, section 8. L11 was not run
(see the end). Run on 2026-11-04.

## Setup

- Mac mini, macOS 26.6.1, SIP off, AMFI off (`amfi_get_out_of_my_way`), so this says nothing about
  AMFI (L0). Two Ethernet interfaces on one LAN, `en0` (primary) and `en1`.
- Other software on the Mac had its own Network Extensions running the whole time: another
  transparent proxy, a packet tunnel, Tailscale and the spike's extension.
- **The stand-in VPN:** a throwaway WireGuard tunnel (`wg-quick`, `AllowedIPs = 0.0.0.0/0`, so it
  installs `0/1` and `128/1` on `utun9`) to a peer on another LAN machine that NATs to a second
  internet line. A request through the VPN shows `VPN_IP`, one around it shows `HOME_IP`.
- **The bundle:** `make bundle` from this branch, with the app's executable replaced by
  `scripts/ne-live/main.swift` (a command line that does what `FlowEngineManager` will: activation,
  configuration, start, policy push with the 30 s heartbeat, status). Built and signed with
  `scripts/ne-live/make-test-app.sh` (Developer ID, both profiles, not notarized), installed as
  `/Applications/VPN Bypass NE Test.app`.
- **The listed app:** a copy of `/usr/bin/curl` named `ne5-fetch`, matched by executable name
  (`bypass-app-0`). Plain `curl` is the unlisted app.
- Both approvals were given once on the mini: "“VPNBypass” would like to use a new network
  extension" (then the switch under General > Login Items & Extensions > Extensions, By Category >
  Network Extensions (i), and the admin authorization), and "“VPN Bypass” Would Like to Add Proxy
  Configurations" (Allow).

## Results

### Claiming works, and the extension answers every message at once

With the policy pushed and the tunnel up: `ne5-fetch` saw `HOME_IP` for `http://` and `https://`;
`curl` and `nscurl` saw `VPN_IP`. The reply to every push and status request came in 0 to 3 ms:
1,000 status requests 10 ms apart, 600 back to back, and every heartbeat of the soak below, with no
reply missing. A status request sent 0 ms after the session turned `connected` was answered too, so
the spike's three missing replies were not reproduced. `FlowPolicy.echoTimeoutSeconds` stays 10 s.

### A route-only full-tunnel VPN breaks scoping to the primary interface (new finding)

With the policy naming no interface the extension picked `en0`, and every claimed connection waited
with no route. `curl --interface en0` failed the same way, `curl --interface en1` worked. The cause
is in the routing table:

```
0/1        utun9          UScg   utun9
default    <router>       UGScg  en0      <- primary: unscoped default only
default    <router>       UGScIg en1      <- secondary: interface-scoped default
128.0/1    utun9          USc    utun9
```

A socket required to use `en0` finds no `en0`-scoped default, so it never connects. Adding one by
hand (`route add -ifscope en0 default <router>`) made both `curl --interface en0` and the claimed
flow work at once. GlobalProtect in the spike (B1) registers itself as the primary service, which
leaves the physical interface with a scoped default, so it did not show this. `wg-quick` and other
VPNs that add `0/1` and `128/1` routes without becoming the primary service do. On a Mac with one
physical interface, per-app routing cannot carry flows past such a VPN without a scoped default
route on that interface.

What this step does about it, so the listed app is never left without a connection:
- a connection that goes to `waiting` before it was ever ready fails at once, instead of after the
  10 s give-up;
- after two failed connects in a row on an interface the extension stops claiming flows for it for
  30 s (`EgressHealth`, decline reason `egressUnusable`), then tries one claim again. On the mini the
  listed app's first request still got its answer in 0.16 s: `curl` moved on to the next address after
  the fast failures, and that one was declined and went through the VPN.

Whether the helper should add the scoped default route (a kernel route, which the design so far
keeps out of the engine) is a decision for a later step. The L-tests below name `en1` in the policy.

### L1: a start or a stop leaves unclaimed flows alone

Open the whole time: two unclaimed downloads through the VPN (HTTP and HTTPS), one claimed download.
`stop-session`, `start`, `turn-off`, `start`: both unclaimed downloads ran on through all four; the
claimed one ended at the first stop, as expected. The WireGuard handshake kept renewing.

### L8: `kill -9`

One claimed and one unclaimed request every 0.5 s, a claimed and two unclaimed downloads open.
After the kill:
- every new TCP connection, claimed or not, waited until about 5.4 s after the kill, then went
  through (requests started 0.02 s after the kill took 5.4 s, ones started 4.6 s after took 0.75 s);
- from then on the listed app went through the VPN (`VPN_IP`), with normal times;
- the claimed download died, both unclaimed downloads and the tunnel survived;
- the session turned `disconnected` with the configuration still enabled, and no extension process
  came back in 2 minutes (a first run: none in 10 minutes).

The 5 s stall is the OS's "extension exit timer". Nothing in the extension can shorten it, because
the extension is dead while it runs. What limits it is how often it can happen: the app's watchdog
(at most one automatic restart, then off, design 3.7), which comes with `FlowEngineManager`.

### L9: updates

- **In-place bundle swap** (old bundle removed, new one moved in, as Homebrew does), with the
  engine active: nothing happened. The old extension kept running, the session stayed connected and
  every flow, claimed ones included, went on (watched for 75 s).
- **A real `brew upgrade`** of a local test cask (`6.0.905` to `6.0.906`, quarantined like a real
  cask): the same. Watched for 7 minutes: same extension process, session connected, the claimed
  download still running.
- **The replacement happens only when the app files the activation request again** from the new
  bundle: "replacing extension 6.0.901 with 6.0.903", no approval asked, old one
  `terminated waiting to uninstall on reboot`. The session ended (`disconnected`, configuration still
  enabled) and the OS did not start it again; claimed flows died about 5 s later, unclaimed ones and
  the tunnel survived. So after a replacement the app must start the session and push again (6.4).
- **`brew uninstall`** with the engine active: the app is gone, the extension stays
  `activated enabled` and keeps running with its policy. The listed app was still sent around the
  VPN until the lease ran out. After that it declines every flow, but the include rule stays, so every
  new TCP connection still passes through it until a manual removal (whether a reboot ends it is L11, not run). This is why the
  in-app "Remove per-app routing" (step 7) matters.

### L13 / B3.2: lease expiry

Policy held with the 30 s heartbeat, then the holder killed (the app quitting). Last push at
`05:51:36`; the listed app saw `HOME_IP` until `05:53:36` and `VPN_IP` from `05:53:40` (the
watchdog runs every 5 s). The reply then said `policyGeneration 0`, `policyLive false`,
`leaseExpiries 1`.

### B2: 10 minutes with the policy held and the VPN up

159 rounds, every 2 to 5 s, of: the listed and an unlisted app asking for their address, and both
loading five public sites over HTTPS. The Mac's own traffic (other jobs, Tailscale, the downloads) went
through the include rule the whole time.
- The listed app saw `HOME_IP` 159 times, the unlisted `VPN_IP` 158 times (one round timed out for
  both).
- Sites: 772 of 795 loads answered 200 through the extension, 786 of 795 through the VPN; the rest
  were 503s and timeouts from the sites, on both sides.
- 20 heartbeats, none missed, all answered in 0 to 1 ms.
- The claimed download and both unclaimed ones ran the full 10 minutes. 943 flows claimed, 279 MB
  carried, 1,370 flows declined as `noMatch`, 10 as `bound` (all bound to a physical interface, by
  other software on the Mac).
- Same extension process from start to end; resident memory 8.8 MB at the start, 9.8 MB at the end.

The first soak counted 630 claimed flows as `aborted` although every load answered. Those were the
client resetting its own connection once it had the answer. The extension now counts that as
`appReset` and keeps `aborted` for failures on the server side.

### L4, bound flows

`boundByInterface` worked: flows bound by `curl --interface` and by other software on the mini were
counted as `physical`. On this Mac `nscurl https://` arrived unbound (declined as `noMatch`), unlike
the spike's B4 beside GlobalProtect. Which interface NSURLSession binds to beside GlobalProtect is
still for the owner's Mac.

## Not run: L11 (reboot and login)

The mini runs other people's and other agents' jobs; a reboot or a logout would have killed them.
L11 needs a quiet window on the mini, or a spare Mac.

## Cleanup

Configuration removed, extension deactivated (`terminated waiting to uninstall on reboot`), test app
and test cask tap removed, tunnel down and its peer deleted, signing material and profiles deleted
from the mini, keychain search list restored.

## Step 6: the app's own switch, live

Run on the same mini on 2026-11-04, with `scripts/ne-live/make-test-app.sh --engine`: the bundle's
executable is `scripts/ne-live/engine-main.swift`, which runs the app's own `FlowEngineManager` and
`LiveFlowEngineSystem` unchanged, with a Custom policy for one listed app and `en1` as the interface.
The whole app could not run there: another VPN Bypass and its helper are installed on that Mac.

- **The stand-in VPN:** a WireGuard tunnel to a peer that does not exist, with `AllowedIPs` set to
  the one public address of an IP-echo service. Anything sent to that address through the tunnel is
  lost, so a request that answers went around it.
- **The listed app:** a copy of `curl` named `ne6-fetch`. Plain `curl` is the unlisted app.

| Step | State the manager showed | `ne6-fetch` | `curl` |
|---|---|---|---|
| Switch on, no extension yet | `awaitingExtensionApproval`, then `awaitingConfigApproval` after the first approval, then `active` after Allow | | |
| Active | `active` | 200 in 0.16 s | timed out (8 s) |
| `ne6-fetch --interface en1` | `active`, and the next reply counted 1 bound flow for the rule | 200 | |
| Pause | `paused (pause)`, policy with 0 app rules | timed out | |
| Resume | `active` | 200 | |
| `kill -9` the extension | `failed (stoppedRestarting)`, then `active` 1 s later | 200 | |
| `kill -9` again within 10 minutes | `failed (stoppedTwice)`, configuration disabled | timed out | timed out |
| Switch on again, then off | `active` without a prompt (the configuration existed), then `off` | 200, then timed out | timed out |

With the switch off, the address still went to the tunnel by the kernel route, as before.

Found and fixed on the way: `LiveFlowEngineSystem` watched the session status with
`queue: .main`. NetworkExtension posts that notification from the main queue, and the post waits for
the observer's operation, so when the main queue is not drained by the main thread's run loop (the
driver uses `dispatchMain()`) the post waited on itself and the manager stayed in `starting`. The
observer now runs on the posting thread and hops to the main actor.

Cleanup: configuration removed, extension 6.0.907 deactivated (`terminated waiting to uninstall on
reboot`), test app, tunnel and signing material deleted, keychain search list as it was, and the
system extension authorization rule back to `authenticate-admin-nonshared`.

## R12: the helper's scoped default route, live

Run on the same mini on 2026-11-04, macOS 26.6.1, for the step that closes R12.

- **The stand-in VPN:** a throwaway `wg-quick` tunnel (`AllowedIPs = 0.0.0.0/0`, so `0/1` and
  `128/1` on `utun9`) to a peer on another LAN machine that NATs to a second internet line.
  `VPN_IP` is that line's address, `HOME_IP` the mini's own.
- **The bundle:** `make-test-app.sh --engine` (extension 6.0.909, then 6.0.910), with
  `engine-main.swift` given `--route-driver` and `--gateway`: the app's `FlowEngineManager` decides
  when to ask for the route (`syncEgressRoute`), and each request runs the helper's own code
  (`ScopedDefaultKeeper`, `HelperTool`, `ScopedDefaultRoute`) from `scoped-route-main.swift` under
  `sudo`. The installed helper of the other VPN Bypass on the mini was not replaced, so the XPC hop
  itself is covered by the unit tests only.
- **The listed app:** a copy of `curl` named `ne9-fetch`, Custom rule with Direct on `en0`.

### What macOS keeps with the half routes up

```
0/1                utun9              UScg                utun9
default            <router>           UGScg                 en0    <- primary: unscoped only
default            <router>           UGScIg                en1    <- secondary: scoped
default            link#27            UCSIg               utun4    <- another tunnel's scoped default
128.0/1            utun9              USc                 utun9
```

`route -n get 1.1.1.1` named `utun9`; `route -n get -ifscope en0 1.1.1.1` answered "not in table";
`curl --interface en0` failed in 0.01 s (exit 7), `curl --interface en1` reached `HOME_IP`. macOS
never adds a scoped default for the primary interface; the half routes win for everything unscoped.
`route -n add -ifscope en0 default <router>` by hand gave `default <router> UGScIg en0`, after which
`curl --interface en0` reached `HOME_IP` and plain `curl` still `VPN_IP`; deleting it brought the
first state back.

### The engine with the helper's route

| Step | Route on `en0` | `ne9-fetch` | `curl` |
|---|---|---|---|
| Switch on, both approvals | `route set en0: added` logged before the first push; `UGS1cIg en0` | `HOME_IP` on the first connect (one `Trying`, 0.14 to 0.17 s) | `VPN_IP` |
| Control: route deleted by hand | none | first two connects fail (exit 7, 4 ms), the third goes to `VPN_IP` (cooldown) | `VPN_IP` |
| Next heartbeat (30 s) | `added` again | `HOME_IP` | |
| Route deleted, two failures, then Pause and Resume 2 s later | `absent` at Pause, `added` at Resume, new stamp in the policy | `HOME_IP` 4 s after the failures, inside the 30 s cooldown (the extension forgot them) | |
| Switch off | `route clear: removed`, table back to the first state | `VPN_IP` | `VPN_IP` |

An earlier build that only named the interface in the policy (no stamp) did not forget the failures
when the route came back with the same interface named: the listed app went to `VPN_IP` until the
cooldown ran out. That is why each route the helper puts in again gets a new stamp.

The driver also showed the boundary checks: `set utun9 ...` and `set en0 fe80::1` were refused, a
router that is not the interface's own default gave `refused`, and a second `set` answered `kept`
with no write.

Cleanup: configuration removed and extension 6.0.910 deactivated by the switch (`terminated waiting
to uninstall on reboot`, as were 6.0.909), test app, driver, tunnel, the peer and its NAT rules
deleted, no scoped default of ours left, signing keychain deleted and the search list as it was, and
the system extension authorization rule back to `authenticate-admin-nonshared`. The mini was not
restarted.
