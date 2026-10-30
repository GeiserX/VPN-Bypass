#!/bin/bash
# gaps.sh <label>: per stream, seconds with zero bytes, when it ended, and the longest ssh silence.
# A stream that ended early shows fewer samples and an early EOF; compare with the run's events log.
cd /Volumes/Data/scratch/ne-partA
l=$1
for f in dl80 dl443; do
  awk -v n="$l-$f" '$2=="EOF"{eof=$1; tot=$3; next} {c++; if(first=="")first=$1; last=$1; if($2==0){z++; zs=zs" "$1} if(min==""||$2<min)min=$2; tot=$3} END{printf "%s: %d samples %s..%s, EOF at %s, zero-byte seconds %d%s, min/s %s, total %s\n", n, c, first, last, (eof==""?"none":eof), z, zs, min, tot}' "$l-$f.log"
done
python3 - "$l-ssh.log" <<'PY'
import sys
from datetime import datetime
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
t=[datetime.strptime(r[0],'%H:%M:%S') for r in rows if len(r)==2 and r[1].count(':')==2]
gaps=[((b-a).seconds, a.strftime('%T')) for a,b in zip(t,t[1:])]
print(f"{sys.argv[1]}: {len(t)} ticks {t[0].strftime('%T')}..{t[-1].strftime('%T')}, longest gap {max(gaps)}")
PY
