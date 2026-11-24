#!/bin/zsh

# Start an iOS simulator, then build, install and start the app on it.
#
#   ./emulate.sh                   an already booted iPhone, else the newest one
#   ./emulate.sh "iPhone 17 Pro"   a specific simulator (name or UDID)
#
# Environment:
#   CONFIGURATION   Debug (default) or Release
#   SIMULATOR       same as the argument

set -euo pipefail

HERE="${0:A:h}"
CONFIGURATION="${CONFIGURATION:-Debug}"
SIMULATOR="${1:-${SIMULATOR:-}}"

# Prints "<udid>\t<name>\t<state>" for the chosen simulator.
PICK="$(xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
want = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]

def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else None

sims = []
for runtime, devices in runtimes.items():
    v = version(runtime)
    if v is None:
        continue
    for index, d in enumerate(devices):
        sims.append((v, index, d))

if want:
    sims = [s for s in sims if want in (s[2]["udid"], s[2]["name"])]
else:
    sims = [s for s in sims if s[2]["name"].startswith("iPhone")]

# Booted first, then newest iOS, then the order Xcode lists them in.
sims.sort(key=lambda s: (s[2]["state"] != "Booted", [-n for n in s[0]], s[1]))
if sims:
    d = sims[0][2]
    print(d["udid"], d["name"], d["state"], sep="\t")
' "$SIMULATOR")"

if [[ -z "$PICK" ]]; then
    print -u2 "No matching simulator${SIMULATOR:+ for \"$SIMULATOR\"}. Available:"
    xcrun simctl list devices available >&2
    exit 1
fi

IFS=$'\t' read -r SIM_ID SIM_NAME SIM_STATE <<<"$PICK"

if [[ "$SIM_STATE" != "Booted" ]]; then
    print "Booting $SIM_NAME..."
    xcrun simctl boot "$SIM_ID"
fi
open -a Simulator --args -CurrentDeviceUDID "$SIM_ID"
xcrun simctl bootstatus "$SIM_ID" >/dev/null

CONFIGURATION="$CONFIGURATION" SIMULATOR_ID="$SIM_ID" "$HERE/build.sh" simulator

APP="$HERE/.build/simulator/Build/Products/$CONFIGURATION-iphonesimulator/Voiced.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

print "Installing on $SIM_NAME..."
xcrun simctl install "$SIM_ID" "$APP"

print "Starting $BUNDLE_ID..."
xcrun simctl launch --terminate-running-process "$SIM_ID" "$BUNDLE_ID"

print "Voiced is running on $SIM_NAME."
