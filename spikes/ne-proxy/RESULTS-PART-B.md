# Part B results: the MacBook beside the corporate VPN, scope `port:80`

Run on 2026-10-30, 14:34 to 14:36 local time, macOS 27, spike 0.1.4 (5), driven from a shell with
the spike CLI. The corporate VPN (a GlobalProtect client) was connected the whole time on a utun
interface and carried both test hosts. HOME_IP is the home line's public address, VPN_IP the VPN's.
Only the owner's two approvals were clicks. Scope `all` (B4) ran later, 15:32 to 15:34 (its own
section below); `kill -9` under `all` was not run.

## B1, egress outside the tunnel

| Command | Matched by | Got |
|---|---|---|
| `spike-fetch http://api4.ipify.org` | app | HOME_IP, 200 in 180 ms |
| `curl -s http://api4.ipify.org` | nothing | VPN_IP |
| `nscurl http://ipv4.icanhazip.com` | host name | HOME_IP |
| `curl -s http://ipv4.icanhazip.com` | host name (macOS fills in the name, as on the mini) | HOME_IP |
| `nscurl http://api4.ipify.org` | nothing | VPN_IP |

A claimed 1 GB download's packets ran on the physical interface (`tcpdump -ni en8 tcp port 80`
showed the server's packets to the Mac's LAN address). Counters after B1: `claimed.app` 2,
`claimed.hostname` 2, `declined.noMatch` 2, `egressOnPolicyInterface` 4, no off-interface egress.

**Answer to question 1: yes.** A claimed flow leaves outside the VPN's tunnel while the VPN is
connected, and unclaimed flows keep going through the tunnel.

## B3, stops

| Step | Result |
|---|---|
| Pause (empty policy) | the next request went to VPN_IP at once |
| Push again | the next request went to HOME_IP |
| Stop session, with a claimed download running | the download ended with -1005 (connection lost) at once; the next request went to VPN_IP |
| `kill -9` (one pid, the README command) | the next port-80 request hung 5.04 s, then went to VPN_IP; later ones took about 0.33 s; the proxy stayed off ("The VPN session failed because an internal error occurred"), no new extension process |

## The VPN client

Its established TCP connections (two, between its own processes on loopback) were identical before
the test and after every step, and the tunnel interface kept its address. HTTPS kept working
throughout. Nothing was restarted, reconnected or reconfigured on the VPN side.

## B4, scope `all` (15:32 to 15:34)

A guard ran beside it, checking HTTPS every 3 s, ready to turn the spike off after two failures; it
never fired.

| Command | Matched by | Got |
|---|---|---|
| `spike-fetch https://api4.ipify.org` | app | HOME_IP, 200 in 306 ms |
| `curl -s https://api4.ipify.org` | nothing | VPN_IP |
| `curl -s https://ipv4.icanhazip.com` | host name | HOME_IP |
| `nscurl https://ipv4.icanhazip.com` | declined as `bound` | VPN_IP |
| `spike-fetch http://api4.ipify.org` | app | HOME_IP |

The VPN client's connections were unchanged right after the start and after two minutes of HTTPS
traffic (16 requests to two sites, all 200 in about 0.6 s), the tunnel kept its address, and its log
showed no error. `flowsSeen` 57 in that time, almost all declined.

New finding: an NSURLSession HTTPS flow (`nscurl`) arrived already bound to an interface and was
declined (`declined.bound`), so a host-name rule did not apply to it while it did to `curl`. The
design must find out which clients bind their flows (and to what) before promising host-name rules
for HTTPS.

`kill -9` under `all` was not run on this Mac.

## Left

- B2 (10 minutes of normal use) and B3.2 (lease expiry after quitting the app) were not run.
