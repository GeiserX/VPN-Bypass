#!/usr/bin/env python3
"""Fail when the privileged helper's code changed but its version did not.

The app reinstalls the helper only when the running helper reports a version other
than HelperConstants.helperVersion. A change to helper code that keeps the version
ships in the app bundle and never reaches an installed helper: 6.0.3 to 6.0.7 did
exactly that, and the 6.0.7 wildcard fix never ran on upgraded Macs.

The helper's code is every file under Helper/ plus every file the Makefile's
build-helper recipe compiles (read from the Makefile, so a file added to the helper
build is covered with no edit here). A change to the recipe's swiftc commands (the
file list or a flag) counts as a change too.

Compares BASE with HEAD and fails when:
  - HelperConstants.helperVersion (Sources/VPNBypassCore/HelperProtocol.swift) and
    Helper/Info.plist CFBundleShortVersionString disagree at HEAD, or
  - a helper file changed between BASE and HEAD while either version did not go up
    (an equal or lower number can match a helper installed from an older release).

BASE defaults to the latest v* tag reachable from HEAD's parent, which is what installed
helpers were built from; the parent, so a run on a commit auto-tag has just tagged still
compares with the release before it. Needs the tags and history (fetch-depth: 0 in CI).

Usage:
    scripts/check-helper-version.py                          # last v* tag .. HEAD
    scripts/check-helper-version.py --base v6.0.6 --head v6.0.7

Exits 0 when the check passes, 1 when it fails, 2 when git cannot answer.
"""

import argparse
import plistlib
import re
import subprocess
import sys

CONSTANT_FILE = "Sources/VPNBypassCore/HelperProtocol.swift"
PLIST_FILE = "Helper/Info.plist"


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"error: git {' '.join(args)}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return result.stdout


def show(ref, path):
    return git("show", f"{ref}:{path}")


def recipe_sources(makefile):
    """The .swift and .h files named in the build-helper recipe."""
    files, inside = set(), False
    for line in makefile.splitlines():
        if re.match(r"^build-helper\s*:", line):
            inside = True
            continue
        if inside:
            if line.startswith("\t") or not line.strip():
                files.update(re.findall(r"[\w./+-]+\.(?:swift|h)\b", line))
            else:
                break
    return files


def compile_commands(makefile):
    """The swiftc commands of the build-helper recipe, continuation lines joined, so a
    change to a flag (-O, -target) or to the file list counts as a helper change."""
    commands, inside, pending = [], False, ""
    for line in makefile.splitlines():
        if re.match(r"^build-helper\s*:", line):
            inside = True
            continue
        if inside:
            if not (line.startswith("\t") or not line.strip()):
                break
            part = line.strip()
            if part.endswith("\\"):
                pending += part[:-1].strip() + " "
                continue
            command, pending = (pending + part).strip(), ""
            if "swiftc" in command:
                commands.append(" ".join(command.split()))
    return commands


def helper_files(ref):
    listed = {p for p in git("ls-tree", "-r", "--name-only", ref, "--", "Helper").splitlines() if p}
    return listed | recipe_sources(show(ref, "Makefile"))


def constant_version(ref):
    match = re.search(r'static let helperVersion\s*=\s*"([^"]+)"', show(ref, CONSTANT_FILE))
    if not match:
        print(f"error: no helperVersion in {CONSTANT_FILE} at {ref}", file=sys.stderr)
        sys.exit(2)
    return match.group(1)


def plist_version(ref):
    return plistlib.loads(show(ref, PLIST_FILE).encode()).get("CFBundleShortVersionString")


def newer(head, base):
    """True when version head is above base, compared number by number."""
    try:
        return tuple(map(int, head.split("."))) > tuple(map(int, base.split(".")))
    except (AttributeError, ValueError):
        print(f"error: helper versions must be dotted numbers, got {head!r} and {base!r}",
              file=sys.stderr)
        sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", help="ref installed helpers come from (default: last v* tag)")
    parser.add_argument("--head", default="HEAD", help="ref to check (default: HEAD)")
    args = parser.parse_args()
    base = args.base or git("describe", "--tags", "--abbrev=0", "--match", "v*", f"{args.head}^").strip()

    head_constant, head_plist = constant_version(args.head), plist_version(args.head)
    print(f"helper version at {args.head}: {head_constant} (constant), {head_plist} (Info.plist)")
    if head_constant != head_plist:
        print(f"FAIL: HelperConstants.helperVersion is {head_constant} but {PLIST_FILE} says "
              f"{head_plist}. Bump both together.")
        return 1

    base_files, head_files = helper_files(base), helper_files(args.head)
    changed = set(git("diff", "--name-only", base, args.head, "--",
                      *sorted(base_files | head_files)).split())
    if compile_commands(show(base, "Makefile")) != compile_commands(show(args.head, "Makefile")):
        changed.add("Makefile (build-helper swiftc commands)")
    if not changed:
        print(f"helper code unchanged since {base}")
        return 0

    base_constant, base_plist = constant_version(base), plist_version(base)
    print(f"helper code changed since {base} (helper {base_constant}):")
    for path in sorted(changed):
        print(f"  {path}")
    if not (newer(head_constant, base_constant) and newer(head_plist, base_plist)):
        print(f"FAIL: the helper changed but its version {head_constant} is not above "
              f"{base_constant}, so installed helpers at that version never reinstall "
              f"(an older number may match a helper still installed from an older release) "
              f"and never get this change. Raise "
              f"HelperConstants.helperVersion in {CONSTANT_FILE} and CFBundleShortVersionString "
              f"in {PLIST_FILE} together, with a comment on the constant saying what it carries.")
        return 1
    print(f"helper version bumped {base_constant} -> {head_constant}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
