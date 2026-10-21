#!/bin/zsh
#
# 删除 install.sh（或应用菜单）安装的 voiced 命令。应用本身不受影响。
#
# 用法：
#   ./uninstall.sh                 # 删除 /usr/local/bin/voiced
#   PREFIX=~/.local ./uninstall.sh # 删除 ~/.local/bin/voiced

set -euo pipefail

BIN_DIR="${PREFIX:-/usr/local}/bin"
TARGET="$BIN_DIR/voiced"

if [[ ! -e "$TARGET" ]]; then
    print "voiced is not installed at $TARGET."
    exit 0
fi

SUDO=()
[[ -w "$BIN_DIR" ]] || SUDO=(sudo)

"${SUDO[@]}" rm -f "$TARGET"
print "Removed $TARGET"
