#!/bin/zsh
#
# Voiced Input 服务（core/.build/voiced）：构建、启动、停止、重启、查看状态。
# 启动、停止、重启和状态由 voiced 命令完成，这里只是同一入口。
#
# 用法：
#   ./core.sh                       # 显示菜单，选择要做的事
#   ./core.sh build                 # 只构建，不影响正在运行的服务
#   ./core.sh start [ui] [文件夹]   # 启动服务，并在每次登录时自动启动（同 voiced start）
#   ./core.sh stop [ui]             # 停止服务，登录时不再启动（同 voiced stop）
#   ./core.sh restart [ui] [文件夹] # 重新构建后重启服务
#   ./core.sh status                # 显示状态（同 voiced status）

set -euo pipefail

ROOT="${0:A:h}"
NAME="${0:t}"
ACTIONS=(build start stop restart status)

usage() {
    print -u2 "Usage: $NAME [build | start [ui] [folder] | stop [ui] | restart [ui] [folder] | status]"
    exit 2
}

choose() {
    local PROMPT3="Voiced Input: "
    select action in "${ACTIONS[@]}"; do
        [[ -n "$action" ]] && { print -r -- "$action"; return; }
    done
    exit 1
}

action="${1:-$(choose)}"
(( $# == 0 )) || shift

case "$action" in
    build)
        (( $# == 0 )) || usage
        "$ROOT/core/build.sh"
        ;;
    restart)
        # voiced restart only restarts the binary that is already built; build first so source
        # changes take effect.
        "$ROOT/core/build.sh"
        "$ROOT/voiced" restart "$@"
        ;;
    start|stop|status)
        "$ROOT/voiced" "$action" "$@"
        ;;
    *) usage ;;
esac
