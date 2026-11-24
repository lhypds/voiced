#!/bin/zsh
#
# macOS 应用：构建、启动、停止、重启。
#
# 用法：
#   ./macos.sh            # 显示菜单，选择要做的事
#   ./macos.sh build      # 构建 macos/.build/Voiced.app
#   ./macos.sh start      # 启动（需要时先构建）
#   ./macos.sh stop       # 退出
#   ./macos.sh restart    # 重新构建后重启
#
# 发布用 macos/release.sh。

set -euo pipefail

ROOT="${0:A:h}"
MACOS="$ROOT/macos"
NAME="${0:t}"
ACTIONS=(build start stop restart)

usage() {
    print -u2 "Usage: $NAME [${(j: | :)ACTIONS}]"
    exit 2
}

choose() {
    local PROMPT3="macOS: "
    select action in "${ACTIONS[@]}"; do
        [[ -n "$action" ]] && { print -r -- "$action"; return; }
    done
    exit 1
}

(( $# <= 1 )) || usage
action="${1:-$(choose)}"

case "$action" in
    build) "$MACOS/Scripts/build-app.sh" ;;
    start) "$MACOS/start.sh" ;;
    stop) "$MACOS/stop.sh" ;;
    restart) "$MACOS/restart.sh" ;;
    *) usage ;;
esac
