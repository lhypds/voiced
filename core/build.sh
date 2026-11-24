#!/bin/zsh
#
# 构建 Voiced Input 服务，输出单个可执行文件 core/.build/vd（Info.plist 嵌入其中）。
# 以固定标识签名，是为了让辅助功能权限在重新构建后依然有效。

set -euo pipefail

ROOT="${0:A:h}"
BINARY="$ROOT/.build/vd"

cd "$ROOT"
swift build -c release

# The service used to be built as an app bundle; remove it so only one copy is around.
rm -rf "$ROOT/.build/VoicedInput.app"

cp "$ROOT/.build/release/VoicedInput" "$BINARY"
codesign \
    --force \
    --sign - \
    --identifier com.local.voiced.input \
    --requirements '=designated => identifier "com.local.voiced.input"' \
    "$BINARY"

print "Built $BINARY"
