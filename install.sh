#!/bin/zsh
#
# 安装 voiced 命令：链接到仓库根目录的 voiced 脚本，之后在终端输入 voiced 即可使用。
#   voiced                          启动 voiced 服务；voiced stop / restart 停止、重启
#   voiced start [macos|ios]        启动 Mac 版，或在所选 iPhone / 模拟器上启动 iOS 版
#   voiced status                   查看状态
# 命令是链接，修改 ./voiced 或重新构建后不用重装。
# 同时删除旧版安装的 vd 命令。
#
# 用法：
#   ./install.sh                 # 安装到 /usr/local/bin（需要时会要求 sudo 密码）
#   PREFIX=~/.local ./install.sh # 安装到 ~/.local/bin
#
# 卸载：./uninstall.sh。

set -euo pipefail

ROOT="${0:A:h}"
BIN_DIR="${PREFIX:-/usr/local}/bin"
TARGET="$BIN_DIR/voiced"

# sudo only when the bin directory, or the nearest ancestor that exists, is not writable.
PROBE="$BIN_DIR"
while [[ ! -e "$PROBE" ]]; do PROBE="${PROBE:h}"; done
SUDO=()
[[ -w "$PROBE" ]] || SUDO=(sudo)

"${SUDO[@]}" mkdir -p "$BIN_DIR"
# -f replaces the launcher script earlier versions installed at the same path.
"${SUDO[@]}" ln -sfn "$ROOT/voiced" "$TARGET"
print "Installed $TARGET"

# vd was the service command before it was merged into voiced.
OLD="$BIN_DIR/vd"
if [[ -L "$OLD" && "$(readlink "$OLD")" == "$ROOT/vd" ]]; then
    "${SUDO[@]}" rm -f "$OLD"
    print "Removed $OLD (now voiced)"
fi

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    print "Note: $BIN_DIR is not in your PATH. Add it to your shell profile to run voiced by name."
fi
