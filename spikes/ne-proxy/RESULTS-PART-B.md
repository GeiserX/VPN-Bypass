# Part B results: the MacBook beside the corporate VPN, scope `port:80`

Run on 2026-10-30, 14:34 to 14:36 local time, macOS 27, spike 0.1.4 (5), driven from a shell with
the spike CLI. The corporate VPN (a GlobalProtect client) was connected the whole time on a utun
interface and carried both test hosts. HOME_IP is the home line's public address, VPN_IP the VPN's.
Only the owner's two approvals were clicks. Scope `all` (B4) was not run.

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

## Left

- B2 (10 minutes of normal use) and B3.2 (lease expiry after quitting the app) were not run.
- B4, scope `all`: not run. Expected risk from Part A: for about 5 s after a crash, every new
  outbound TCP connection hangs, the VPN client's new ones included.
