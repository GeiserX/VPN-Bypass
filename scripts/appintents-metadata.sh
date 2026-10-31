#!/bin/bash
# Writes Contents/Resources/Metadata.appintents into the app bundle, which is how Shortcuts
# finds the app's actions (Sources/VPNBypassCore/ShortcutIntents.swift). Xcode writes it with
# its "Extract App Intents Metadata" step; the app is built with `swift build`, which has no
# such step, so this does it with the same tool, `appintentsmetadataprocessor`.
#
# The tool reads the compiler's constant values for VPNBypassCore. The Swift Build engine
# (SwiftPM 6.3 and newer) writes them during `make build`; an older SwiftPM does not, and then
# this script builds VPNBypassCore once more, for one architecture, with the flags that write
# them. Fails when the result does not list every action, so a bundle never ships without them.
#
# Usage: scripts/appintents-metadata.sh "VPN Bypass.app"

set -euo pipefail

APP="${1:?usage: $0 <app bundle>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE=VPNBypassCore
ACTIONS=(AddDomainIntent GetStatusIntent SetModeIntent SetServiceIntent)
WORK="$ROOT/.build/appintents"
rm -rf "$WORK/meta" "$WORK/lists"
mkdir -p "$WORK/meta" "$WORK/lists"

# One architecture's constant values: they name types, not addresses, so either will do.
CONSTS=$(find "$ROOT/.build" -path "$WORK" -prune -o -path "*/arm64/*" -name "$MODULE*.swiftconstvalues" -print 2>/dev/null \
         | xargs ls -t 2>/dev/null | head -1 || true)

newer_sources() { find "$ROOT/Sources/$MODULE" -name '*.swift' -newer "$1" -print -quit; }

# A file older than any source may be from an earlier build: its titles or parameters could
# differ from the code in the bundle, so it is not used.
if [ -n "$CONSTS" ] && [ -n "$(newer_sources "$CONSTS")" ]; then
    echo "The constant values $CONSTS are older than the sources; ignoring them."
    CONSTS=""
fi

if [ -z "$CONSTS" ]; then
    CONSTS="$WORK/$MODULE.swiftconstvalues"
    if [ -s "$CONSTS" ] && [ -z "$(newer_sources "$CONSTS")" ]; then
        echo "Using the constant values from the last run of this script."
    else
        echo "No constant values from the build; building $MODULE once more to write them..."
        # A clean build: an incremental one may compile nothing and so write nothing.
        rm -rf "$WORK/build" "$CONSTS"
        # The protocols whose conformances the tool needs, as Xcode lists them.
        PROTOCOLS="$WORK/lists/protocols.json"
        echo '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' > "$PROTOCOLS"
        NATIVE=()
        # The flags below only work on the native build system; Swift Build adds its own.
        if swift build --help 2>&1 | grep -q -- '--build-system'; then NATIVE=(--build-system native); fi
        swift build --package-path "$ROOT" -c release --arch arm64 "${NATIVE[@]}" --target "$MODULE" \
            --scratch-path "$WORK/build" \
            -Xswiftc -emit-const-values-path -Xswiftc "$CONSTS" \
            -Xswiftc -const-gather-protocols-list -Xswiftc "$PROTOCOLS"
        [ -s "$CONSTS" ] || { echo "error: the compiler wrote no constant values for $MODULE" >&2; exit 1; }
    fi
fi

echo "$CONSTS" > "$WORK/lists/constvalues.txt"
find "$ROOT/Sources/$MODULE" -name '*.swift' | sort > "$WORK/lists/sources.txt"

DEVELOPER="$(xcode-select -p)"
xcrun appintentsmetadataprocessor \
    --output "$WORK/meta" \
    --toolchain-dir "$DEVELOPER/Toolchains/XcodeDefault.xctoolchain" \
    --module-name "$MODULE" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS \
    --deployment-target 13.0 \
    --target-triple arm64-apple-macos13.0 \
    --source-file-list "$WORK/lists/sources.txt" \
    --swift-const-vals-list "$WORK/lists/constvalues.txt"

DATA="$WORK/meta/Metadata.appintents/extract.actionsdata"
[ -s "$DATA" ] || { echo "error: appintentsmetadataprocessor wrote no $DATA" >&2; exit 1; }
for action in "${ACTIONS[@]}"; do
    python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["actions"] else 1)' "$DATA" "$action" \
        || { echo "error: Metadata.appintents has no $action" >&2; exit 1; }
done

rm -rf "$APP/Contents/Resources/Metadata.appintents"
cp -R "$WORK/meta/Metadata.appintents" "$APP/Contents/Resources/"
echo "Shortcuts actions: ${ACTIONS[*]} (Metadata.appintents from $(basename "$CONSTS"))"
