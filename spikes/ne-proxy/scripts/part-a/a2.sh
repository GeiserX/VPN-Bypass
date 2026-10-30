#!/bin/bash
# A2 run: a2.sh <label> <port:80|all|control>
set -u
label=$1; mode=$2
D=/Volumes/Data/scratch/ne-partA; cd "$D"
B="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/VPNBypassNESpike"
spike() { sudo launchctl asuser "$(id -u sergio)" sudo -u sergio "$B" "$@"; }
ev() { echo "$(date +%T) $*" | tee -a "$label-events.log"; }
ts() { sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED | grep -i tailscale | awk '{print $1, $2, $9}' | sort > "$label-ts-$1.txt"; ev "tailscale snapshot $1: $(wc -l < "$label-ts-$1.txt") connections"; }
: > "$label-events.log"
if [ "$mode" != control ]; then ev "spike status before:"; spike status 2>&1 | tee -a "$label-events.log"; fi
# the three unrelated connections
( ssh -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@"$OTHER" 'while :; do date +%T; sleep 1; done' 2>&1; echo "ssh exit $?" ) | python3 -u stamp.py > "$label-ssh.log" 2>&1 &
( curl -sS --limit-rate 1M http://ipv4.download.thinkbroadband.com/1GB.zip; echo "curl80 exit $?" >&2 ) 2>"$label-dl80.err" | python3 -u meter.py > "$label-dl80.log" &
( curl -sS --limit-rate 1M https://fsn1-speed.hetzner.com/1GB.bin; echo "curl443 exit $?" >&2 ) 2>"$label-dl443.err" | python3 -u meter.py > "$label-dl443.log" &
sleep 10
ev "connections open: $(sudo lsof -nP -iTCP -sTCP:ESTABLISHED -a -c curl -c ssh | grep -c -E 'curl|ssh ')"
ts T0
if [ "$mode" = control ]; then
  ev "control: turn-off skipped"; sleep 10; ts T1
  ev "control: start skipped"; sleep 30; ts T2
  ev "control: stop-session skipped"; sleep 15; ts T3
else
  ev "turn-off"; spike turn-off 2>&1 | tail -3 | tee -a "$label-events.log"; ev "turn-off returned"
  sleep 10; ts T1
  ev "start --scope $mode"; spike start --scope "$mode" 2>&1 | tee -a "$label-events.log"; ev "start returned"
  sleep 15
  if [ -n "${MID:-}" ]; then
    ev "new flows under the running proxy: https $(curl -sS -o /dev/null -m 10 -w '%{http_code} %{time_total}s' https://api4.ipify.org) http $(curl -sS -o /dev/null -m 10 -w '%{http_code} %{time_total}s' http://api4.ipify.org) ssh $(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$OTHER" true && echo ok || echo FAIL)"
  fi
  sleep 15; ts T2
  ev "status before stop:"; spike status 2>&1 | tee -a "$label-events.log"
  ev "stop-session"; spike stop-session 2>&1 | tail -3 | tee -a "$label-events.log"; ev "stop-session returned"
  sleep 15; ts T3
fi
ev "alive at end: ssh=$(pgrep -f "root@$OTHER while" >/dev/null && echo yes || echo no) curl80=$(pgrep -f 'curl -sS --limit-rate 1M http://' >/dev/null && echo yes || echo no) curl443=$(pgrep -f 'curl -sS --limit-rate 1M https://' >/dev/null && echo yes || echo no)"
pkill -f 'curl -sS --limit-rate 1M http' ; pkill -f "root@$OTHER while"; sleep 2
for f in ssh dl80 dl443; do ev "$f tail: $(tail -2 "$label-$f.log" | tr '\n' '|')"; done
cat "$label-dl80.err" "$label-dl443.err" >> "$label-events.log"
for t in T1 T2 T3; do ev "tailscale T0 vs $t: $(diff "$label-ts-T0.txt" "$label-ts-$t.txt" >/dev/null && echo same || echo DIFFERENT)"; done
