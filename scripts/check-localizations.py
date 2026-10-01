#!/usr/bin/env python3
"""Fail when a localizable string in Sources/ has no Spanish or French entry.

Also fails when a Spanish or French entry's format specifiers differ from its
key's, ignoring their order ("%1$@ y %2$@" matches "%@ and %@").

The keys come from the Swift compiler, not from a regex over the source: an
interpolation's placeholder depends on its type ("\\(count)" is %lld for an Int,
%@ for a String), and the compiler is the only reader that knows the type. It
writes every literal passed to String(localized:), Text, Button, Label, .help
and the other localizable APIs to a .stringsdata file per source file.

Usage:
    scripts/check-localizations.py                     # builds VPNBypassCore in a temp dir
    scripts/check-localizations.py --stringsdata DIR   # reads .stringsdata files already under DIR

Keys with no letter outside their format specifiers ("%lld/%lld", "8080") are
skipped. Names and examples that read the same in every language ("SOCKS5",
"example.com") still need an entry, with the English text as the value, so the
catalog says they were looked at.

Needs macOS (swift, plutil). Exits 1 and lists the keys when any are missing.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources" / "VPNBypassCore" / "Resources"
LANGUAGES = ["es", "fr"]
# A format specifier: %@, %lld, %1$@, %.1f ...
SPECIFIER = re.compile(r"%(\d+\$)?[-+ #0-9.]*((?:hh|h|ll|l|q|L)?[@dDiuUxXoOfeEgGcCsSp%])")


def needs_translation(key: str) -> bool:
    """A key with no letter outside its format specifiers ("%lld/%lld", "8080", "*") reads the same in every language."""
    return any(ch.isalpha() for ch in SPECIFIER.sub("", key))


def build(scratch: Path) -> Path:
    """Compile VPNBypassCore from scratch so every file writes its keys."""
    out = scratch / "strings"
    out.mkdir(parents=True)
    result = subprocess.run(
        [
            "swift", "build", "--package-path", str(ROOT), "--target", "VPNBypassCore",
            "--scratch-path", str(scratch / "build"),
            "-Xswiftc", "-emit-localized-strings",
            "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(out),
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"error: swift build failed\n{result.stdout}{result.stderr}")
    return scratch


def source_keys(root: Path) -> dict:
    """{(table, key): ["File.swift:line", ...]} for every key the compiler saw in Sources/."""
    keys: dict = {}
    files = list(root.rglob("*.stringsdata"))
    if not files:
        sys.exit(f"error: no .stringsdata files under {root}; the compiler wrote no keys")
    for path in files:
        data = json.loads(path.read_text())
        source = Path(data.get("source", ""))
        if (ROOT / "Sources") not in source.parents:
            continue
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                where = f"{source.relative_to(ROOT)}:{entry.get('location', {}).get('startingLine', '?')}"
                if needs_translation(entry["key"]):
                    keys.setdefault((table, entry["key"]), []).append(where)
    return keys


def catalog(language: str, table: str) -> dict:
    path = RESOURCES / f"{language}.lproj" / f"{table}.strings"
    if not path.exists():
        return {}
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def specifiers(text: str) -> list:
    """Each specifier's length and conversion, ignoring position: "%2$lld" and "%lld" are both "lld"."""
    return sorted(m.group(2) for m in SPECIFIER.finditer(text) if m.group(2) != "%")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stringsdata", type=Path, help="directory holding .stringsdata files from a build")
    args = parser.parse_args()

    if args.stringsdata:
        keys = source_keys(args.stringsdata)
    else:
        with tempfile.TemporaryDirectory(prefix="vpnb-loc-") as tmp:
            keys = source_keys(build(Path(tmp)))

    if not keys:
        sys.exit("error: the compiler wrote no keys under Sources/; the source-path filter matched nothing")
    tables = sorted({table for table, _ in keys})
    catalogs = {(lang, table): catalog(lang, table) for lang in LANGUAGES for table in tables}
    missing = 0
    for lang in LANGUAGES:
        for (table, key), places in sorted(keys.items(), key=lambda item: item[1][0]):
            if key not in catalogs[(lang, table)]:
                missing += 1
                print(f"{lang}.lproj/{table}.strings is missing {json.dumps(key, ensure_ascii=False)}  ({places[0]})")
    # A translation whose specifiers differ from its key's reads the wrong argument, or
    # crashes on one: "%@" given an Int.
    mismatched = 0
    for (lang, table), entries in sorted(catalogs.items()):
        for key, value in entries.items():
            if specifiers(key) != specifiers(value):
                mismatched += 1
                print(f"{lang}.lproj/{table}.strings: {json.dumps(key, ensure_ascii=False)} has the specifiers "
                      f"{specifiers(key)}, its translation {specifiers(value)}")
    if missing or mismatched:
        print(f"\n{missing} missing translation(s), {mismatched} with the wrong specifiers, "
              f"across {', '.join(LANGUAGES)}.", file=sys.stderr)
        return 1
    print(f"All {len(keys)} localizable keys in Sources/ have {' and '.join(LANGUAGES)} entries, "
          f"with the same specifiers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
