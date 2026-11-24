#!/bin/zsh
#
# 构建 Voiced Input 服务，打包为 core/.build/VoicedInput.app。
# 打包成应用并固定签名标识，是为了让辅助功能权限在重新构建后依然有效。

set -euo pipefail

ROOT="${0:A:h}"
APP_DIR="$ROOT/.build/VoicedInput.app"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT/.build/release/VoicedInput" "$APP_DIR/Contents/MacOS/VoicedInput"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.local.voiced.input"' \
    "$APP_DIR"

print "Built $APP_DIR"
