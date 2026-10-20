#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/.build/Voiced.app"
ICON="$ROOT/Support/AppIcon.icns"

cd "$ROOT"
swift build -c release

# The icon is checked in; only regenerate it when missing. Run Scripts/generate-icon.sh to refresh it.
if [[ ! -f "$ICON" ]]; then
    "$ROOT/Scripts/generate-icon.sh"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/Voiced" "$APP_DIR/Contents/MacOS/Voiced"
cp "$ROOT/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.local.voiced"' \
    "$APP_DIR"

print "Built $APP_DIR"
