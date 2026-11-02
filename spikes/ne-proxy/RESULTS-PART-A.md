# NE proxy spike: Part A results (the Mac mini)

Run on 2026-10-30, 13:57 to 14:14 local time (CET), on the Mac mini: macOS 26.6.1, SIP off,
`amfi_get_out_of_my_way`, no GlobalProtect. Tailscale was connected the whole time and was not
touched. Extension 0.1.4 (5), `[activated enabled]`. Every step ran over `ssh` through the app's
command line (`spike ...`, see the README's "Drive it from a shell"). Nobody clicked anything.

The drivers are in `scripts/part-a/`: `a2.sh` (A2), `a3.sh` (A3), `meter.py` (bytes per second of a
download), `stamp.py` (receive time of each `ssh` line), `gaps.sh` (finds stalls). The raw logs stayed
on the mini because they hold addresses.

## Short version

- **A1, matching:** works by app and by host name. One difference from the README: plain `curl` to a
  host in the list is **claimed** too, even when it connects to an IP literal. macOS fills in
  `remoteHostname` for flows that are not connect-by-name.
- **A2, start and stop (L1):** nothing the proxy did not claim was disturbed, with scope `port:80` and
  with scope `all`. That covers a port-80 download, a port-443 download, an `ssh` session, and Tailscale's
  three connections. Not one second without bytes and not one `ssh` gap over 1 s. Tailscale kept
  the same three sockets from 13:58 to 14:12. The control period looked the same.
- **A3, kill -9 (L8):** two things the README does not say.
  1. **For 5 s after the kill, every new flow the include rule covers hangs.** That is port 80 under
     `port:80`, and every outbound TCP flow under `all`. Then macOS gives up on the extension
     ("Extension exit timer expired"), and those flows go out directly.
  2. **macOS does not restart the extension.** The session stays `disconnected` ("The VPN session
     failed because an internal error occurred"), the configuration stays enabled, and no extension
     process comes back. We waited more than 3 minutes. From then on traffic goes direct (fail-open)
     until something runs `spike start`. The README's "the OS restarts it on `port:80`" did not happen.

  Connections that were already open and that the proxy had not claimed survived: `ssh`, an unclaimed
  download, Tailscale. The claimed download died at the 5 s mark, not at the moment of the kill.
- **Part B is safe to run**, with the conditions at the end of this file.

## A1: matching by app and by host name

13:57:21, scope `port:80`, `spike push --apps com.geiserx.vpn-bypass.spike.fetch --hosts
ipv4.icanhazip.com` (no `--hold`, so a 2-minute lease). The counters are cumulative and were read
after each command.

| # | Command | Result | Counter change |
|---|---|---|---|
| 1 | `"$F" http://api4.ipify.org` | `200 in 157 ms` | `claimed.app` 1→2, `egressOnPolicyInterface` 1→2 |
| 2 | `curl -s http://api4.ipify.org` | the public IP | `declined.noMatch` 0→1 |
| 3 | `nscurl http://ipv4.icanhazip.com` | the public IP | `claimed.hostname` 0→1, `egressOnPolicyInterface` 2→3 |
| 4 | `curl -s http://ipv4.icanhazip.com` | the public IP | **`claimed.hostname` 1→2** (README expected `declined.noMatch`) |

Row 4 was checked again at 13:57:34 with a fresh push:

| Command | Counter change |
|---|---|
| `/usr/bin/curl http://ipv4.icanhazip.com` (curl 8.7.1, SecureTransport) | `claimed.hostname` 2→3 |
| `/usr/bin/curl -H "Host: ipv4.icanhazip.com" http://<its IP>/` (IP literal) | `claimed.hostname` 3→4 |
| `/usr/bin/curl http://api4.ipify.org` | `declined.noMatch` 1→2 |
| `nc -z ipv4.icanhazip.com 80` | `claimed.hostname` 4→5 |

**What this means.** The extension matches on `NEAppProxyFlow.remoteHostname` alone
(`FlowDecider.hostname(of:)`). On macOS 26.6.1 that field was also set for curl, for `nc`, and for a
connect to an IP literal of a host the Mac had just resolved. So the OS seems to take the name from
recent DNS answers, not only from connect-by-name calls. Before this run, the IP had last been
resolved by curl's own lookup in row 4. Two consequences for the design:

1. Host-name matching covers more clients than "NSURLSession only". This is good for VPN Bypass.
2. The flip side, which we have not tested: a flow to an IP that a listed name shares (one CDN address
   for many sites) may be claimed as that name. Test this before we trust host-name matching on
   shared IPs.

Without a VPN every answer was the same public IP, so here the counters are the result.

## A2 (L1): does a start or a stop close flows the proxy does not claim?

First `spike pause` (13:57:53, policy with 0 apps and 0 hosts). Each run then opened these and let
them run for 10 s:

- an `ssh` session to another box on the tailnet (a 100.64/10 address, so it never matches either
  scope's include rule), printing the remote clock every second, with `ServerAliveInterval=5`;
- `curl --limit-rate 1M http://ipv4.download.thinkbroadband.com/1GB.zip` (port 80: in the include
  rule for both scopes, declined, because curl is not in the policy);
- `curl --limit-rate 1M https://fsn1-speed.hetzner.com/1GB.bin` (port 443: in `all`'s include rule
  only);
- Tailscale's own established TCP connections (`sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED`), three
  of them, all to public addresses on 443, so they are in `all`'s include rule. The snapshot keeps
  the local port, so a reconnect would show as a difference.

Then: `spike turn-off`, 10 s, `spike start --scope <S>`, 30 s, `spike stop-session`, 15 s, with
Tailscale snapshots T0 (before) to T3.

| Run | What it stopped and started (the extension's own log) | Download 80 | Download 443 | `ssh` | Tailscale T0 vs T1/T2/T3 |
|---|---|---|---|---|---|
| `port:80` (13:57:53–13:58:59) | turn-off of a **connected** `port:80` proxy 13:58:03.654 `stopped reason=9`; `started scope=80` 13:58:13.759; `stopped reason=1` 13:58:44.404 | 66 s, 0 zero-byte seconds, min 819200 B/s | 66 s, 0 zero-byte seconds, min 802816 B/s | 66 ticks, longest gap 1 s | same / same / same |
| `all` (13:59:20–14:00:26) | the proxy was already stopped, so turn-off stopped nothing; `started scope=0` (all) 13:59:40.824; `stopped reason=1` 14:00:11.455 | 0 zero-byte seconds, min 819200 B/s | 0 zero-byte seconds, min 606208 B/s | longest gap 1 s | same / same / same |
| `all`, again (14:00:47–14:01:53) | `started scope=0` 14:00:41.809; turn-off of a **connected** `all` proxy 14:00:57.516 `stopped reason=9`; `started scope=0` 14:01:07.616; `stopped reason=1` 14:01:38.701 | 0 zero-byte seconds, min 196608 B/s | 0 zero-byte seconds, min 212992 B/s | longest gap 1 s | same / same / same |
| control (14:02:03–14:03:08), spike not touched | none | 0 zero-byte seconds, min 917504 B/s | 0 zero-byte seconds, min 933888 B/s | longest gap 1 s | same / same / same |

In the second `all` run, new flows opened 15 s after the start, while the proxy was running with no
policy, went through untouched. That was 14:01:23: `https://api4.ipify.org` 200 in 0.17 s,
`http://api4.ipify.org` 200 in 0.13 s, a new `ssh` ok. `declined.noPolicy` went from 0 to 5.

The three Tailscale sockets were the same ones in every snapshot from the first run (13:58) to the
last one of A3 (14:12).

**The stall detector can fail.** At 14:03:26 a positive control sent SIGSTOP to the two curls and to
`ssh` for 5 s. `gaps.sh` then reported 6 and 5 zero-byte seconds on the downloads and a 6 s gap on
`ssh`.

A small finding: turn-off, start and stop-session do not end the extension process. The pid stayed
99674 through all A2 runs. Only `kill -9` gave a new one.

## A3 (L8): kill -9

`a3.sh` ran once with each scope. Each time it did `spike turn-off`, `spike start --scope <S>`, and
`spike push --apps com.geiserx.vpn-bypass.spike.fetch --hosts ipv4.icanhazip.com --hold` in the
background (30 s heartbeat). It then started `"$F" --every 120 http://api4.ipify.org`, which is
claimed by app. Alongside ran an unclaimed `curl` probe every 0.5 s to `http://` and to
`https://api4.ipify.org`, the `ssh` session, an unclaimed port-80 download, and a claimed
`"$F" --download` that started 3 s before the kill. The pid came from the README's exact command and
was checked to be one number.

### Scope `port:80` (the kill at 14:08:14; a first run at 14:04:50 gave the same timings)

```
14:08:14 pid command printed: [32045] (1 value(s))
14:08:14 kill -9 32045
spike-fetch --every (claimed):
  14:08:13  200 in 132 ms
  14:08:14  error -1001 after 5011 ms: The request timed out.
  14:08:19  error -1000 after 269 ms: bad URL
  14:08:20  200 in 138 ms            (direct from here on: the session is down)
unclaimed probe, http (in the include rule):
  14:08:14.439 200 0.137628s
  14:08:15.126 200 4.810061s         (held until the session was torn down, then direct)
  14:08:20.486 200 0.127123s
unclaimed probe, https (outside port:80): every request 0.14-0.17 s through the kill
claimed download: 14:08:19 stream ended with error -1005: The network connection was lost., 192118919 bytes
nesessionmanager: 14:08:19.797 Extension exit timer expired ... notify that extension failed
                  14:08:19.801 status changed to disconnected, last stop reason Plugin failed
status t+2 s to t+40 s: proxy: disconnected, configuration enabled; no extension process;
  last disconnect error: The VPN session failed because an internal error occurred.
ssh: 125 ticks, longest gap 1 s; unclaimed download: 0 zero-byte seconds; Tailscale T0 vs T1: same
```

The first run (kill at 14:04:50): `spike-fetch` timed out once (5004 ms), then `-1000 bad URL`, then
went direct from 14:04:56. The claimed download was lost at 14:04:55. `Extension exit timer expired`
came at 14:04:55.912. The session was still `disconnected` at 14:07:22, 2.5 minutes after the kill,
with no extension process.

### Scope `all` (the kill at 14:10:47)

```
14:10:47 pid command printed: [37418] (1 value(s))
14:10:47 kill -9 37418
unclaimed probe, http:  14:10:47.893 200 4.786738s
unclaimed probe, https: 14:10:48.045 200 4.650219s   (under all, 443 is held as well)
spike-fetch --every (claimed): 14:10:48 error -1000 after 4390 ms: bad URL, then 200 direct
claimed download: 14:10:52 stream ended with error -1005: The network connection was lost., 170917319 bytes
nesessionmanager: 14:10:52.572 Extension exit timer expired
status t+2 s to t+40 s: proxy: disconnected, configuration enabled; no extension process
ssh: 128 ticks, longest gap 1 s; unclaimed download: 0 zero-byte seconds; Tailscale T0 vs T1: same
```

Background noise, not from the spike: in all four probe logs, 1 to 4 https requests took about 1.15 s.
One of them was at 14:09:04, when the session was already down. `spike-fetch` timed out once at
14:12:11, also with the session down.

### What A3 answers

- **New flows:** for about 5 s after the crash (kill to "exit timer expired"), a new flow that the
  include rule covers waits. When macOS drops the session, the flow is released and goes out
  directly. The one exception is a claimed request that was already in flight: it timed out. Flows
  outside the include rule (https under `port:80`) see nothing.
- **Open flows:** a flow the proxy claimed dies at the 5 s mark. A flow it did not claim, or never
  saw, survives. That was `ssh`, the declined port-80 download, and Tailscale's three sockets.
- **Restart and scope:** none. No new pid, the session stayed `disconnected`, and the configuration
  stayed enabled. So the README's "A start by the OS is always `port:80`" (restart after a crash or
  `kill -9`) and "Do not `kill -9` the extension to stop it: ... the OS starts it again" were not seen
  on macOS 26.6.1. A crash leaves the proxy off, and traffic goes direct. In this run, `kill -9`
  stopped it.

## Other things seen

- `spike status` sometimes printed `(no reply from the extension)` while the session was
  `connected`. That happened 3 times in A3: twice with no download running and once during a
  full-speed claimed download. The next call answered. The reply came back empty or too late for the
  CLI; why was not investigated. It is only a display problem here, but a heartbeat that depends on a
  reply would need a retry.
- In the `all` A3 run, `flowOpenFailed = 1` before the kill. Not investigated.
- `pkill` from the driver could not signal the root `sudo` wrapper of `push --hold` ("Operation not
  permitted"), but the `push` process itself ended: `pgrep` found none afterwards.

## State left on the mini

14:13:57 `spike turn-off`: `configuration disabled`, `proxy: disconnected, configuration disabled`,
no extension process. `systemextensionsctl` still lists 0.1.4/5 as `[activated enabled]`, and the
extensions of the other two VPN configurations are unchanged. Tailscale is still connected, with the
same three sockets.

## Part B on the MacBook: safe, with these conditions

Part A's gate for scope `all` is met: unclaimed connections survived a start and a stop under `all`.
A3 adds conditions that the README does not have yet:

1. **`port:80` steps (B1, B2, B3.1 to B3.3) can run.** Nothing in Part A touched a connection the
   proxy did not claim, and with `port:80` GlobalProtect's own TLS connections are never offered to
   the extension.
2. **B3.4 (`kill -9`) under `port:80` can run**, but expect these outcomes and do not read them as a
   failure: claimed requests and downloads die about 5 s later; new port-80 flows hang for about 5 s,
   then go through the VPN; and **the proxy stays off afterwards**. Run `spike start` and `spike push`
   again before the next step. Tailscale's sockets survived on the mini.
3. **Scope `all` (B4, and any B3 step under `all`) can run**, with one known risk: during the 5 s
   after a crash or `kill -9`, **every** new outbound TCP connection hangs. That includes new
   connections GlobalProtect opens itself (portal, HIP), because the team exclusion runs inside the
   dead extension. The tunnel connection it already has should survive, as Tailscale's did. Run B3.4
   under `all` only if a 5 s stall of GlobalProtect's new connections is acceptable. If GlobalProtect
   drops anyway, follow the README rule: Turn off, note the time, and reconnect it yourself.
4. **Unchanged from the README:** the owner installs and approves on the MacBook. Nothing in Part A
   activated or ran anything there. Never restart or reconfigure GlobalProtect to make a step work.
5. **Expect host-name matching to claim plain `curl` too.** In B1, row 4 (`curl -s
   http://ipv4.icanhazip.com`) will probably show HOME_IP and `claimed.hostname`, not VPN_IP. That is
   the A1 finding, not a leak.
6. Before Part B, correct the README in three places: A1 row 4, "A start by the OS is always
   `port:80`" plus the restart in A3, and the "Do not `kill -9`" note.
