#!/bin/zsh

# Build, install and start the app on a real iPhone.
#
#   ./deploy.sh                     first connected/paired iPhone
#   ./deploy.sh "Heyang's iPhone"   a specific device (name, identifier or UDID)
#
# Environment:
#   CONFIGURATION   Debug (default) or Release
#   DEVICE          same as the argument
#
# The iPhone must be paired, unlocked, and have Developer Mode enabled.

set -euo pipefail

HERE="${0:A:h}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEVICE="${1:-${DEVICE:-}}"

if [[ -z "$DEVICE" ]]; then
    JSON="$(mktemp -t voiced-devices)"
    trap 'rm -f "$JSON"' EXIT
    xcrun devicectl list devices --json-output "$JSON" >/dev/null
    # Prefer a device that is reachable right now; fall back to any paired iPhone.
    DEVICE="$(/usr/bin/python3 - "$JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
]
# Reachable now first: transportType (wired or localNetwork) is missing while the iPhone cannot be
# reached; tunnelState is "disconnected" until a deploy opens a tunnel, so it says nothing.
phones.sort(key=lambda d: not d.get("connectionProperties", {}).get("transportType"))
if phones:
    print(phones[0]["identifier"])
PY
)"
    if [[ -z "$DEVICE" ]]; then
        print -u2 "No paired iPhone found. Connect one, unlock it and trust this Mac."
        print -u2 "Known devices:"
        xcrun devicectl list devices >&2 || true
        exit 1
    fi
fi

CONFIGURATION="$CONFIGURATION" "$HERE/build.sh" device

APP="$HERE/.build/device/Build/Products/$CONFIGURATION-iphoneos/Voiced.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

print "Installing on $DEVICE..."
xcrun devicectl device install app --device "$DEVICE" "$APP"

print "Starting $BUNDLE_ID..."
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_ID"

print "Deployed Voiced to $DEVICE."
