#!/bin/zsh
#
# 构建 voiced 服务（macOS），输出单个可执行文件 service/.build/voiced（Info.plist 嵌入其中）。
# 以固定标识 com.local.voiced.input 签名，辅助功能权限在重新构建后依然有效。
# 平时用 voiced service build / voiced service restart。
#
# Windows 上：cargo build --release，得到 target\release\voiced.exe。

set -euo pipefail

# Run from a shell that did not read the zsh profile (PowerShell, say), PATH may lack where
# Homebrew and rustup put cargo and the rest.
for dir in "$HOME/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]] && path+=("$dir")
done

ROOT="${0:A:h}"
BINARY="$ROOT/.build/voiced"

cd "$ROOT"
cargo build --release

mkdir -p "$ROOT/.build"
cp "$ROOT/target/release/voiced" "$BINARY"
codesign \
    --force \
    --sign - \
    --identifier com.local.voiced.input \
    --requirements '=designated => identifier "com.local.voiced.input"' \
    "$BINARY"

print "Built $BINARY"
