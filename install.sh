#!/bin/zsh
#
# 安装 voiced 命令：在 /usr/local/bin 下放一个启动脚本，之后在终端输入 voiced 即可打开 Voiced。
# 应用本身留在 .build/Voiced.app，restart.sh 重新构建后命令不用重装。
#
# 用法：
#   ./install.sh                 # 安装到 /usr/local/bin/voiced（需要时会要求 sudo 密码）
#   PREFIX=~/.local ./install.sh # 安装到 ~/.local/bin/voiced
#
# 卸载：./uninstall.sh。应用的 Voiced 菜单里也有同样的安装项。

set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.build/Voiced.app"
BIN_DIR="${PREFIX:-/usr/local}/bin"
TARGET="$BIN_DIR/voiced"

cd "$ROOT"

if [[ ! -d "$APP" ]]; then
    "$ROOT/Scripts/build-app.sh"
fi

# sudo only when the bin directory, or the nearest ancestor that exists, is not writable.
PROBE="$BIN_DIR"
while [[ ! -e "$PROBE" ]]; do PROBE="${PROBE:h}"; done
SUDO=()
[[ -w "$PROBE" ]] || SUDO=(sudo)

LAUNCHER="#!/bin/sh
# Opens Voiced. Installed by install.sh; remove with uninstall.sh.
exec open \"$APP\""

"${SUDO[@]}" mkdir -p "$BIN_DIR"
print -r -- "$LAUNCHER" | "${SUDO[@]}" tee "$TARGET" >/dev/null
"${SUDO[@]}" chmod 755 "$TARGET"

print "Installed $TARGET"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    print "Note: $BIN_DIR is not in your PATH. Add it to your shell profile to run voiced by name."
fi
