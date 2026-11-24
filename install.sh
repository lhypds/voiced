#!/bin/zsh
#
# 安装 voiced 和 vd 命令。
# voiced：在 /usr/local/bin 下放一个启动脚本，之后在终端输入 voiced 即可打开 Voiced。
# voiced stop 退出应用，voiced restart 重新启动，voiced start 与不带参数相同。
# vd：链接到仓库根目录的 vd 脚本，控制 Voiced Input 服务（vd start / stop / restart [ui]、vd status）。
# 应用本身留在 macos/.build/Voiced.app，macos/restart.sh 重新构建后命令不用重装。
#
# 用法：
#   ./install.sh                 # 安装到 /usr/local/bin（需要时会要求 sudo 密码）
#   PREFIX=~/.local ./install.sh # 安装到 ~/.local/bin
#
# 卸载：./uninstall.sh。应用的 Voiced 菜单里也有同样的安装项。

set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/macos/.build/Voiced.app"
BIN_DIR="${PREFIX:-/usr/local}/bin"
TARGET="$BIN_DIR/voiced"

cd "$ROOT"

if [[ ! -d "$APP" ]]; then
    "$ROOT/macos/Scripts/build-app.sh"
fi

# sudo only when the bin directory, or the nearest ancestor that exists, is not writable.
PROBE="$BIN_DIR"
while [[ ! -e "$PROBE" ]]; do PROBE="${PROBE:h}"; done
SUDO=()
[[ -w "$PROBE" ]] || SUDO=(sudo)

# The launcher body below is the same script the app's menu installs; keep it in step with
# macos/Sources/Voiced/Models/CommandLineTool.swift.
LAUNCHER_HEAD="#!/bin/sh
# Starts, stops or restarts Voiced. Installed by install.sh; remove with uninstall.sh.
#
# Usage: voiced [start|stop|restart]   (no argument means start)

APP=\"$APP\""

LAUNCHER_BODY="$(cat <<'BODY'
EXECUTABLE="$APP/Contents/MacOS/Voiced"

running() {
    pgrep -f -- "$EXECUTABLE" >/dev/null
}

start() {
    if running; then
        # open brings the running app to the front.
        open "$APP"
        echo "Voiced is already running."
    else
        open "$APP" && echo "Started Voiced."
    fi
}

stop() {
    if ! running; then
        echo "Voiced is not running."
        return 0
    fi
    pkill -f -- "$EXECUTABLE"
    # Wait for the process to exit, so a following start opens a new one instead of
    # activating the old one.
    i=0
    while running && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if running; then
        echo "Voiced did not stop." >&2
        return 1
    fi
    echo "Stopped Voiced."
}

case "${1:-start}" in
    start) start ;;
    stop) stop ;;
    restart) stop && start ;;
    *)
        echo "Usage: voiced [start|stop|restart]" >&2
        exit 2
        ;;
esac
BODY
)"

"${SUDO[@]}" mkdir -p "$BIN_DIR"
{ print -r -- "$LAUNCHER_HEAD"; print -r -- "$LAUNCHER_BODY"; } | "${SUDO[@]}" tee "$TARGET" >/dev/null
"${SUDO[@]}" chmod 755 "$TARGET"

print "Installed $TARGET"

# vd is a link, so edits to ./vd take effect without reinstalling.
"${SUDO[@]}" ln -sfn "$ROOT/vd" "$BIN_DIR/vd"
print "Installed $BIN_DIR/vd"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    print "Note: $BIN_DIR is not in your PATH. Add it to your shell profile to run voiced and vd by name."
fi
