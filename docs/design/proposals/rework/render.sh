#!/usr/bin/env bash
# Render every rework mockup (NN-*.html, NNx-*.html) in this folder to a PNG at 2x.
# Usage: ./render.sh [file.html ...]   (default: all numbered mockups)
# PLAYWRIGHT points at a Playwright CLI; it defaults to `npx playwright`.
# Run pngquant --quality 80-95 over each PNG afterwards.
set -euo pipefail
cd "$(dirname "$0")"
PW=${PLAYWRIGHT:-"npx playwright"}
files=("$@")
[ ${#files[@]} -eq 0 ] && files=([0-9][0-9]*-*.html)
for f in "${files[@]}"; do
  out="${f%.html}.png"
  $PW screenshot --device "Desktop Chrome HiDPI" --viewport-size "300,200" --full-page \
    "file://$PWD/$f" "$out" >/dev/null
  echo "$out $(wc -c <"$out" | tr -d ' ') bytes"
done
