#!/bin/zsh
#
# 删除 install.sh（或应用菜单）安装的 voiced 命令，以及旧版的 vd 命令。
# 应用本身和 voiced 服务不受影响；要停止服务，先运行 voiced stop。
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
# voiced is either the link to this checkout or the app-only launcher script the Voiced menu
# installs for a downloaded app.
TARGET="$BIN_DIR/voiced"
ours() {
    if [[ -L "$TARGET" ]]; then
        [[ "$(readlink "$TARGET")" == "$ROOT/voiced" ]]
    else
        [[ -f "$TARGET" ]] && grep -q "Starts, stops or restarts Voiced" "$TARGET"
    fi
}
if ours; then
    "${SUDO[@]}" rm -f "$TARGET"
    print "Removed $TARGET"
    removed=1
fi
# vd was the service command before it was merged into voiced.
OLD="$BIN_DIR/vd"
if [[ -L "$OLD" && "$(readlink "$OLD")" == "$ROOT/vd" ]]; then
    "${SUDO[@]}" rm -f "$OLD"
    print "Removed $OLD"
    removed=1
fi
(( removed )) || print "voiced is not installed in $BIN_DIR."
