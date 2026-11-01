#!/usr/bin/env bash
# Renders release notes for a fake version in a throwaway repository and fails unless:
#   - with docs/release-notes/<version>.md, the file's content comes first, word for word,
#     right above "## What's Changed";
#   - without it, the notes start with "## What's Changed";
#   - every commit since the previous tag is listed (no silent cap);
#   - release.yml really builds its notes with scripts/release-notes.sh.
# CI runs it in the test job. Usage: scripts/test-release-notes.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/release-notes.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

grep -q 'scripts/release-notes.sh' "$ROOT/.github/workflows/release.yml" \
  || fail "release.yml does not call scripts/release-notes.sh"

cd "$WORK"
git init -q -b main .
git config user.name test
git config user.email test@example.invalid
# Leave out any hooks or signing from the machine's own git config.
git config core.hooksPath /dev/null
git config commit.gpgsign false
git config tag.gpgsign false
git commit -q --allow-empty -m "chore: start"
git tag v1.0.0
# More of each kind than the old caps (20 features, 20 fixes, 10 others).
for i in $(seq 1 25); do git commit -q --allow-empty -m "feat: feature $i"; done
for i in $(seq 1 22); do git commit -q --allow-empty -m "fix: fix $i"; done
for i in $(seq 1 14); do git commit -q --allow-empty -m "docs: doc $i"; done
git tag v2.0.0

export GITHUB_REPOSITORY=example/repo

check_lists() {
  local out=$1 label=$2
  [ "$(grep -c '^- feat: feature ' "$out")" -eq 25 ] || fail "$label: expected 25 features, got $(grep -c '^- feat: feature ' "$out")"
  [ "$(grep -c '^- fix: fix ' "$out")" -eq 22 ] || fail "$label: expected 22 fixes, got $(grep -c '^- fix: fix ' "$out")"
  [ "$(grep -c '^- docs: doc ' "$out")" -eq 14 ] || fail "$label: expected 14 other changes, got $(grep -c '^- docs: doc ' "$out")"
  grep -qx '\*\*Full Changelog\*\*: https://github.com/example/repo/compare/v1.0.0...v2.0.0' "$out" \
    || fail "$label: compare link missing or wrong"
  grep -qx '\*\*SHA256:\*\* `abc123`' "$out" || fail "$label: SHA256 line missing"
}

# 1. No notes file: the notes open with What's Changed.
"$SCRIPT" 2.0.0 abc123 > without.md
[ "$(head -1 without.md)" = "## What's Changed" ] || fail "without a notes file, line 1 is '$(head -1 without.md)'"
check_lists without.md "without notes file"

# 2. A notes file (no final newline, to catch a glued heading): its content comes first.
mkdir -p docs/release-notes
printf '## Before you upgrade\n\n- Something changes for you.\n\n## What'"'"'s new\n\n- A thing.' > docs/release-notes/2.0.0.md
"$SCRIPT" 2.0.0 abc123 > with.md
n=$(wc -l < docs/release-notes/2.0.0.md); n=$((n + 1))
head -n "$n" with.md > with-head.md
printf '\n' >> docs/release-notes/2.0.0.md
cmp -s with-head.md docs/release-notes/2.0.0.md || { fail "the notes file is not the first thing in the notes"; diff docs/release-notes/2.0.0.md with-head.md || true; }
[ "$(grep -n "^## What's Changed$" with.md | head -1 | cut -d: -f1)" -eq $((n + 2)) ] \
  || fail "What's Changed does not follow the notes file (one blank line between)"
c=$(grep -c '^## Before you upgrade$' with.md || true)
[ "$c" -eq 1 ] || fail "the notes file's heading appears $c times, expected once"
check_lists with.md "with notes file"

# 3. Another version's file is not picked up.
"$SCRIPT" 2.0.1 abc123 > other.md 2>/dev/null
[ "$(head -1 other.md)" = "## What's Changed" ] || fail "a notes file for 2.0.0 leaked into 2.0.1"

if [ "$fails" -gt 0 ]; then
  echo "--- notes rendered with the file:"; cat with.md
  echo "$fails check(s) failed"
  exit 1
fi
echo "release notes: all checks passed"
