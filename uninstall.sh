#!/bin/zsh
#
# 删除 install.sh（或应用菜单）安装的 voiced 和 vd 命令。应用本身和 Voiced Input 服务不受影响；
# 要停止服务，先运行 vd stop。
#
# 用法：
#   ./uninstall.sh                 # 从 /usr/local/bin 删除
#   PREFIX=~/.local ./uninstall.sh # 从 ~/.local/bin 删除

set -euo pipefail

ROOT="${0:A:h}"
BIN_DIR="${PREFIX:-/usr/local}/bin"

SUDO=()
[[ -w "$BIN_DIR" ]] || SUDO=(sudo)

removed=0
if [[ -e "$BIN_DIR/voiced" ]]; then
    "${SUDO[@]}" rm -f "$BIN_DIR/voiced"
    print "Removed $BIN_DIR/voiced"
    removed=1
fi
# Only remove vd when it is the link to this checkout.
VD="$BIN_DIR/vd"
if [[ -L "$VD" && "${VD:A}" == "$ROOT/vd" ]]; then
    "${SUDO[@]}" rm -f "$BIN_DIR/vd"
    print "Removed $BIN_DIR/vd"
    removed=1
fi
(( removed )) || print "voiced and vd are not installed in $BIN_DIR."
