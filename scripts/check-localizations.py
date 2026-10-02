#!/usr/bin/env python3
"""Fail when a localizable string in Sources/ has no Spanish or French entry.

Also fails when a Spanish or French entry's format specifiers differ from its
key's, and when a catalog has a key that no source file uses any more. Each
argument must keep its position and type, wherever it sits in the sentence:
"%2$@ y %1$@" matches "%@ and %@", "%1$@ y %1$@" does not.

The keys come from the Swift compiler, not from a regex over the source: an
interpolation's placeholder depends on its type ("\\(count)" is %lld for an Int,
%@ for a String), and the compiler is the only reader that knows the type. It
writes every literal passed to String(localized:), Text, Button, Label, .help
and the other localizable APIs to a .stringsdata file per source file.

Usage:
    scripts/check-localizations.py                     # builds VPNBypassCore in a temp dir
    scripts/check-localizations.py --stringsdata DIR   # reads .stringsdata files already under DIR

A key no source file uses means a translated string went back to a plain
literal (Text(someString) shows a String as it is, in English), or a string was
removed and its catalog line was not. Either way the line is dead: restore the
lookup or delete the line from en, es and fr.

Keys with no letter outside their format specifiers ("%lld/%lld", "8080") are
skipped. Names and examples that read the same in every language ("SOCKS5",
"example.com") still need an entry, with the English text as the value, so the
catalog says they were looked at.

Needs macOS (swift, plutil). Exits 1 and lists the keys when any are missing,
mismatched or unused.
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
# The reference catalog: checked for unused keys along with the translations.
REFERENCE = "en"
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
    """{(table, key): ["File.swift:line", ...]} for every key the compiler saw in Sources/, letters or not."""
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


def catalog_tables() -> list:
    """Every table any language folder has a .strings file for: "Localizable" for Localizable.strings."""
    return sorted({path.stem for path in RESOURCES.glob("*.lproj/*.strings")})


def unused_keys(keys: dict) -> list:
    """[(language, table, key)] for each catalog line whose key no source file uses."""
    used = set(keys)
    found = []
    for lang in [REFERENCE] + LANGUAGES:
        for table in catalog_tables():
            for key in catalog(lang, table):
                if (table, key) not in used:
                    found.append((lang, table, key))
    return found


def specifiers(text: str) -> list:
    """Each argument's position and conversion: "%@ and %lld" is ["%1$@", "%2$lld"], and so is "%2$lld, %1$@".

    A specifier without "n$" takes the next argument, so "%@ and %@" reads arguments 1 and 2.
    """
    found, implicit = [], 0
    for m in SPECIFIER.finditer(text):
        if m.group(2) == "%":
            continue
        if m.group(1):
            position = int(m.group(1)[:-1])
        else:
            implicit += 1
            position = implicit
        found.append(f"%{position}${m.group(2)}")
    return sorted(found)


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
    unused = unused_keys(keys)
    keys = {entry: places for entry, places in keys.items() if needs_translation(entry[1])}
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
    # A key no source uses: a lookup reverted to a plain String literal, or a string removed
    # without its catalog line.
    for lang, table, key in unused:
        print(f"{lang}.lproj/{table}.strings has {json.dumps(key, ensure_ascii=False)}, which no source file uses")
    if missing or mismatched or unused:
        print(f"\n{missing} missing translation(s), {mismatched} with the wrong specifiers, "
              f"{len(unused)} unused, across {', '.join([REFERENCE] + LANGUAGES)}.", file=sys.stderr)
        return 1
    print(f"All {len(keys)} localizable keys in Sources/ have {' and '.join(LANGUAGES)} entries, "
          f"with the same specifiers, and every catalog key is used.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
