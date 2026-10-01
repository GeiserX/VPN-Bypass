#!/usr/bin/env bash
# Render every proposal mockup (NN-*.html) in this folder to a PNG at 2x.
# Usage: ./render.sh [file.html ...]   (default: all NN-*.html)
# PLAYWRIGHT points at a Playwright CLI; it defaults to `npx playwright`.
set -euo pipefail
cd "$(dirname "$0")"
PW=${PLAYWRIGHT:-"npx playwright"}
files=("$@")
[ ${#files[@]} -eq 0 ] && files=([0-9][0-9]-*.html)
for f in "${files[@]}"; do
  out="${f%.html}.png"
  # "Desktop Chrome HiDPI" sets deviceScaleFactor 2; --full-page grows the small
  # viewport to the page, so the PNG is exactly the mockup at 2x.
  $PW screenshot --device "Desktop Chrome HiDPI" --viewport-size "300,200" --full-page \
    "file://$PWD/$f" "$out" >/dev/null
  echo "$out $(wc -c <"$out" | tr -d ' ') bytes"
done
