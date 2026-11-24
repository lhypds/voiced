#!/bin/zsh

# Build the iOS app.
#
#   ./build.sh            build for the simulator (no signing needed)
#   ./build.sh device     build for a real iPhone (signed with the project's team)
#
# Environment:
#   CONFIGURATION   Debug (default) or Release
#   SIMULATOR_ID    simulator UDID to build for; default builds for any simulator
#
# The last line of output is the path of the built Voiced.app.

set -euo pipefail

HERE="${0:A:h}"
PROJECT="$HERE/Voiced.xcodeproj"
SCHEME="Voiced iOS"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET="${1:-simulator}"

case "$TARGET" in
    sim|simulator)
        DERIVED="$HERE/.build/simulator"
        PRODUCTS="$DERIVED/Build/Products/$CONFIGURATION-iphonesimulator"
        if [[ -n "${SIMULATOR_ID:-}" ]]; then
            DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
        else
            DESTINATION="generic/platform=iOS Simulator"
        fi
        EXTRA=(CODE_SIGNING_ALLOWED=NO)
        ;;
    device|iphone)
        DERIVED="$HERE/.build/device"
        PRODUCTS="$DERIVED/Build/Products/$CONFIGURATION-iphoneos"
        DESTINATION="generic/platform=iOS"
        EXTRA=(-allowProvisioningUpdates)
        ;;
    *)
        print -u2 "Usage: ${0:t} [simulator|device]"
        exit 2
        ;;
esac

LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"

print "Building $SCHEME ($CONFIGURATION, $TARGET)..."
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    "${EXTRA[@]}" \
    build >"$LOG" 2>&1; then
    grep -E "(error|warning: unable|BUILD FAILED)" "$LOG" | sort -u | tail -40 >&2 || true
    print -u2 "Build failed. Full log: $LOG"
    exit 1
fi

APP="$PRODUCTS/Voiced.app"
if [[ ! -d "$APP" ]]; then
    print -u2 "Build succeeded but $APP is missing. Full log: $LOG"
    exit 1
fi

print "Built $APP"
