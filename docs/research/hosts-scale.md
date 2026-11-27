# Large /etc/hosts sections: what they cost on macOS

Research of November 2026, for blocklists on the Block route (#272). Blocklist support writes every listed name as one `0.0.0.0 name` line in its own `/etc/hosts` section. Before we build on that, we measured what a section of 50,000 to 500,000 names does to the Mac's resolver. This page has the method, the numbers and the cap we chose. The script is `scripts/measure-hosts.sh`.

**Terms used below**
- **mDNSResponder:** the macOS process that answers every lookup made through the system resolver (`getaddrinfo`, `dscacheutil`, Safari, most apps). It reads `/etc/hosts`.
- **The flush:** `dscacheutil -flushcache` then `killall -HUP mDNSResponder`. The helper runs it after every hosts write (`HelperTool.flushResolverCaches`).
- **The stall:** the time during which mDNSResponder answers no lookup at all, because it is busy reading a new `/etc/hosts`.
- **Listed / unlisted name:** a name that is / is not in the test section.
- **RSS:** the memory a process holds, as `ps` reports it.

---

## 1. Decision

- **Cap: keep 100,000 names in the app (`H`), with a helper-side ceiling of 200,000.** StevenBlack's unified list (81,677 names) fits, and a cap of 50,000 would shut out that one preset. On macOS 26.6.1 at 100,000 names, adding the section already stalls lookups for 5 to 7 s (removing it 3.2 to 3.4 s, a small write with it in place 3.5 to 4.7 s). At 200,000 it stalls them for 11 to 18 s, and mDNSResponder grows by about 260 MB. macOS 27.2.1 stalls under half as long (section 3). That cost is acceptable only if it comes with real changes, not with every write (next points).
- **Every hosts write stalls every lookup on the Mac while a large section is in place.** It is 2.4 to 3.1 s at 50,000 names, 5.2 to 7.0 s at 100,000 and 10.7 to 18.4 s at 200,000. It happens when a list is added, when it is removed, and on any other write to the file, such as an update of a pinned name. No lookup failed. They all waited.
- **So PR 1 must not write `/etc/hosts` when nothing changed.** Today the helper rewrites the file on every `updateHostsFile` call, even when the content is the same. One such call comes with each DNS refresh (`dnsRefreshInterval`, 3600 s by default). A small changed write with a 100,000-name section in place froze lookups for 3.5 to 4.7 s. A write with identical content was not measured, so we assume it costs the same. The section writer must return early on unchanged content, and so must the pin writer.
- **Keep the flush after every write.** It does not make the stall longer or shorter. With the flush, the stall starts at once and the new names answer when it ends. Section 4 has the case without it.
- **No `::` rows.** With only `0.0.0.0 name`, an IPv6 lookup of the name answers `::ffff:0.0.0.0` and no query leaves the Mac.
- **The section blocks exact names only.** `sub.<listed name>` is not blocked. It goes to the network as usual.
- **Tell the user.** The list settings say that a list change pauses lookups for a few seconds and that mDNSResponder needs about 1 to 2 MB per 1,000 names.

---

## 2. Method

All runs were on an Apple silicon Mac on macOS 26.6.1, idle, on a home network with a local DNS server. Section 3 ends with one run on macOS 27.2.1.

`scripts/measure-hosts.sh` runs as root. It refuses to start unless `/etc/hosts` matches a saved original. On any exit, a trap puts that original back with the same owner and mode. Then it checks the sha256, flushes and checks that `apple.com` resolves. It writes only synthetic names, `nNNNNNNN.vpnb-measure.invalid`, one per line. Each case:

1. It writes the original file plus a section of N names with an atomic rename, mode 0644, as the helper does.
2. From 2 s before the rename, two loops call `getaddrinfo` every 50 ms. One asks for a fresh random name under `iana.org`, which is always unlisted and answers NXDOMAIN from the network. The other asks for `apple.com`, which is unlisted and normally comes from the cache in 2 to 3 ms. They run until a listed name answers `0.0.0.0`, plus 10 s.
3. It writes the same section plus one more name (an unrelated small write while the list is in place) and runs the loops until that name answers.
4. It puts the original back and runs the loops until the listed name stops answering `0.0.0.0`, plus 10 s.

Each size runs once with the flush after each write and once without. A case fails if a listed name never answers `0.0.0.0`, if it never stops after removal, or if `apple.com` fails to resolve even once.

**The check can fail.** `--control` writes every row commented out, so no listed name can answer. That run failed, as it must:

```
{"names": 50000, "flush": true, "control": true, ... "result": "FAIL: listed name never answered 0.0.0.0 within 25 s"}
RESTORED rc=1 sha_match=YES owner_mode=0:0 440 test_lines=0 apple.com_resolves=YES
```

An earlier exploratory run had one pass and no stall loops. It measured lookup times, memory, the time until a new section takes effect, and what leaves the Mac (`tcpdump` on port 53). Its numbers are in section 5.

---

## 3. The stall

The longest single lookup of `apple.com` in each window, in seconds. Two full runs of the matrix (run 1 and run 2), a few minutes apart. The fresh unlisted name stalled for the same time, within 0.9 s. Outside a stall, the longest `apple.com` lookup was 3 ms and the longest fresh-name lookup was 216 ms.

| Names | Flush | Add a list | Small write with the list in place | Remove the list |
|---:|:---:|---:|---:|---:|
| 50,000 | yes | 2.4 / 2.8 | 1.7 | 1.7 / 1.6 |
| 50,000 | no | 2.5 / 3.1 | 1.8 | 1.8 / 1.6 |
| 100,000 | yes | 5.4 / 6.8 | 4.7 | 3.4 / 3.2 |
| 100,000 | no | 5.2 / 7.0 | 3.5 | 3.3 / 3.2 |
| 200,000 | yes | 11.4 / 16.5 | 10.1 | 7.0 / 6.7 |
| 200,000 | no | 10.7 / 18.4 | 10.4 | 6.6 / 6.4 |

(Run 2 / run 1. Run 1 had no small-write step.)

- **The count of lookups slower than 500 ms was 1 in every window**, and 0 in the baseline. Each loop is sequential, so one lookup waited out the whole stall. The length is the number that matters.
- **No lookup failed.** `apple.com` resolved every time, in every case. Lookups wait, and they do not return an error.
- **It grows with the size**, at 50 to 90 µs per name across the two runs: 81,677 names (StevenBlack) would stall about 4 to 7 s.
- **Removing a list stalls about half as long as adding it** (35 to 72% across both runs), even though the new file is small.
- **What a user feels.** For those seconds, every new connection on the Mac waits for its lookup: a page that starts loading, a mail check, a `git fetch`. Connections that are already open are not affected.

### macOS 27

One run of the same script on macOS 27.2.1, on a Mac with the same chip and memory as the macOS 26.6.1 one (Apple M4, 16 GB), idle, with a stock `/etc/hosts`. The longest single lookup of `apple.com` in each window, in seconds:

| Names | Flush | Add a list | Small write with the list in place | Remove the list |
|---:|:---:|---:|---:|---:|
| 50,000 | yes | 0.7 | 0.6 | 0.3 |
| 50,000 | no | 0.5 | 0.5 | 0.3 |
| 100,000 | yes | 2.4 | 2.5 | 0.7 |
| 100,000 | no | 2.5 | 2.1 | 0.7 |

- **The stall is shorter on macOS 27**: about a quarter as long at 50,000 names and under half as long at 100,000. It is still a stall of every lookup (the fresh unlisted name stalled for the same time, within 0.1 s), and it still grows faster than the list: twice the names took about four times as long.
- No lookup of the real name failed. Outside a stall its longest lookup was 37 ms.
- mDNSResponder grew from 13 MB to 94 MB with 50,000 names, about the same as on macOS 26.
- This is one run, so read the numbers as a range, not as exact values. It does not change the cap.

---

## 4. When the new names take effect

Time from the rename until a listed name answered `0.0.0.0`, in seconds:

| Names | Exploratory run, no flush | Run 2, no flush | Run 2, flush |
|---:|---:|---:|---:|
| 50,000 | 1.9 | 0.07 | 2.6 |
| 100,000 | not run | 0.13 | 5.5 |
| 200,000 | 11.4 | 0.24 | 11.7 |
| 500,000 | 60.8 | not run | not run |

- **With the flush,** the stall begins at once and the new names answer when it ends.
- **Without the flush, the runs disagree.** We did not find why. In runs 1 and 2 the new name answered at once and the stall began about 1 s later. In the exploratory run it answered only after about as long as the stall. One difference: in the exploratory run, each case started from the test Mac's original file at mode 0440, which mDNSResponder cannot read (see `HostsFileMode`). In runs 1 and 2, the cases without the flush started from a 0644 file.
- **The exploratory run also timed a flush, but only after the section had loaded** (0.3 s at 50,000 and 200,000, 9.4 s at 500,000). That is the time to answer again after a flush, not the time to load. It does not show that the flush makes a new section load faster.

The stall is the same length with and without the flush, so the flush costs nothing and makes sure the new names take effect. We keep it.

---

## 5. Exploratory run: lookup time, memory, leaks

**Lookup time does not change for unlisted names.** `getaddrinfo` of `apple.com` stayed at 0.2 to 0.3 ms (median, warm) at every size, and 1.5 to 2.2 ms cold. A listed name also answered in 0.2 to 0.3 ms. Only `dscacheutil` of a listed name slowed with size: median 11 ms at 50,000, 31 ms at 200,000 and 81 ms at 500,000. `getaddrinfo`, the call apps use, did not slow.

**Memory.** mDNSResponder RSS, in MB:

| Names | Before | With the section |
|---:|---:|---:|
| 0 | 19 | 19 |
| 50,000 | 19 | 105 |
| 200,000 | 105 | 363 |
| 200,000, 9 names per line | 351 | 360 |
| 500,000 | 322 | 874 |

In run 1, 100,000 names took mDNSResponder from 204 MB to 296 MB. The memory is not returned when the section goes. It is returned slowly afterwards: the same mDNSResponder process (no restart) was down from 874 MB to 108 MB about 25 minutes after the exploratory run. Lines with 9 names each took the same memory and time as one name per line.

**CPU.** mDNSResponder ran at 87 to 99% of one core during each load.

**What leaves the Mac.** For a listed name, neither the IPv4 nor the IPv6 lookup sent a query. The IPv6 lookup answered `::ffff:0.0.0.0`. Only `sub.<listed name>` went to the network (an `A` and an `AAAA` query, NXDOMAIN).

---

## 6. What we did not test

- **Safari with iCloud Private Relay.** Private Relay handles DNS for Safari, and users report that it ignores `/etc/hosts`.
- **Chrome with Secure DNS** and **Firefox with DNS over HTTPS.** Chromium's source reads the hosts file before its own DoH, but we did not check either browser live.
- **macOS 27 at 200,000 names, and a second run.** Section 3 has one run on macOS 27.2.1 at 50,000 and 100,000 names.
- **Intel Macs.** We expect a longer stall on slower CPUs.
- **A write with identical content.** We measured a write that adds one name. The rename replaces the file, so we expect mDNSResponder to read it all again, but we did not measure it. PR 1 avoids that write anyway.
- **Busy Macs.** The test Mac was idle. Under load the stall is likely longer.

To repeat the measurement on another Mac:

```bash
sudo scripts/measure-hosts.sh --control 50000   # must exit 1
sudo scripts/measure-hosts.sh 50000 100000 200000
```
