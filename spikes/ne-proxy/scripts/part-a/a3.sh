#!/bin/bash
# A3 run: a3.sh <label> <port:80|all>
set -u
label=$1; scope=$2
D=/Volumes/Data/scratch/ne-partA; cd "$D"
B="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/VPNBypassNESpike"
F="/Applications/VPN Bypass NE Spike.app/Contents/MacOS/spike-fetch"
spike() { sudo launchctl asuser "$(id -u sergio)" sudo -u sergio "$B" "$@"; }
ev() { echo "$(date +%T) $*" | tee -a "$label-events.log"; }
ts() { sudo lsof +c 0 -nP -iTCP -sTCP:ESTABLISHED | grep -i tailscale | awk '{print $1, $2, $9}' | sort > "$label-ts-$1.txt"; ev "tailscale snapshot $1: $(wc -l < "$label-ts-$1.txt") connections"; }
: > "$label-events.log"
ev "turn-off"; spike turn-off | head -1
ev "start --scope $scope"; spike start --scope "$scope" | sed -n '2,4p' | tee -a "$label-events.log"
nohup sudo launchctl asuser "$(id -u sergio)" sudo -u sergio "$B" push --apps com.geiserx.vpn-bypass.spike.fetch --hosts ipv4.icanhazip.com --hold > "$label-hold.log" 2>&1 &
sleep 3; ev "push --hold running: $(head -1 "$label-hold.log")"
( ssh -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@"$OTHER" 'while :; do date +%T; sleep 1; done' 2>&1; echo "ssh exit $?" ) | python3 -u stamp.py > "$label-ssh.log" 2>&1 &
( curl -sS --limit-rate 1M http://ipv4.download.thinkbroadband.com/1GB.zip; echo "curl80 exit $?" >&2 ) 2>"$label-dl80.err" | python3 -u meter.py > "$label-dl80.log" &
"$F" --every 120 http://api4.ipify.org 2>&1 | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/PUBLIC_IP/g' > "$label-fetch.log" &
FETCH=$!
probe() { local end=$((SECONDS+75)); while [ $SECONDS -lt $end ]; do
  local s=$(python3 -c 'import time;t=time.time();print(time.strftime("%H:%M:%S",time.localtime(t))+(".%03d"%(t%1*1000)))')
  echo "$s $(curl -sS -o /dev/null -m 10 -w '%{http_code} %{time_total}s' "$1" 2>&1 | tail -1 | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g')" >> "$2"; sleep 0.5; done; }
: > "$label-probe80.log"; : > "$label-probe443.log"
probe http://api4.ipify.org "$label-probe80.log" &
probe https://api4.ipify.org "$label-probe443.log" &
sleep 12
ev "status before the claimed download:"; spike status | tee -a "$label-events.log"
"$F" --download http://ipv4.download.thinkbroadband.com/1GB.zip > "$label-claimed-dl.log" 2>&1 &
sleep 3
ev "status before kill:"; spike status | tee -a "$label-events.log"
ts T0
pid=$(ps -axo pid=,comm= | awk '$2 ~ /^\/Library\/SystemExtensions\/[^ ]*\/com\.geiserx\.vpn-bypass\.spike\.proxy$/ {print $1}')
ev "pid command printed: [$pid] ($(echo "$pid" | wc -w | tr -d ' ') value(s))"
[ "$(echo "$pid" | wc -w | tr -d ' ')" = 1 ] || { ev "ABORT: not exactly one pid"; exit 1; }
ev "kill -9 $pid"; sudo kill -9 "$pid"
for i in $(seq 1 20); do
  p=$(ps -axo pid=,comm= | awk '$2 ~ /^\/Library\/SystemExtensions\/[^ ]*\/com\.geiserx\.vpn-bypass\.spike\.proxy$/ {print $1}' | tr '\n' ' ')
  ev "t+${i}s extension pids: [${p}] | $(spike status 2>&1 | sed -n '1,3p' | tr '\n' '|')"
  sleep 1
done
sleep 20; ts T1
ev "status 40 s after kill:"; spike status | tee -a "$label-events.log"
ev "ssh alive=$(pgrep -f "root@$OTHER while" >/dev/null && echo yes || echo no) curl80 alive=$(pgrep -f 'curl -sS --limit-rate 1M http://' >/dev/null && echo yes || echo no)"
ev "waiting for spike-fetch --every to finish"; wait $FETCH
pkill -f 'curl -sS --limit-rate 1M http'; pkill -f "root@$OTHER while"; pkill -f 'spike-fetch --download'; pkill -INT -f "VPNBypassNESpike push"; sleep 2
ev "tailscale T0 vs T1: $(diff "$label-ts-T0.txt" "$label-ts-T1.txt" >/dev/null && echo same || echo DIFFERENT)"
