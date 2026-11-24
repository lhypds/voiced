#!/bin/zsh
#
# 构建 voiced 服务，输出单个可执行文件 core/.build/voiced（Info.plist 嵌入其中）。
# 以固定标识签名，是为了让辅助功能权限在重新构建后依然有效。

set -euo pipefail

ROOT="${0:A:h}"
BINARY="$ROOT/.build/voiced"

cd "$ROOT"
swift build -c release

# The service used to be built as an app bundle, then as .build/vd; remove those so only one copy is around.
rm -rf "$ROOT/.build/VoicedInput.app" "$ROOT/.build/vd"

cp "$ROOT/.build/release/VoicedInput" "$BINARY"
codesign \
    --force \
    --sign - \
    --identifier com.local.voiced.input \
    --requirements '=designated => identifier "com.local.voiced.input"' \
    "$BINARY"

print "Built $BINARY"
