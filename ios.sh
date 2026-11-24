#!/bin/zsh
#
# iOS 应用：构建、在模拟器中运行、安装到 iPhone。
#
# 用法：
#   ./ios.sh                    # 显示菜单，选择要做的事
#   ./ios.sh build              # 构建模拟器版（无需签名）
#   ./ios.sh build device       # 构建真机版（用工程中的 Team 签名）
#   ./ios.sh emulate [模拟器]   # 启动模拟器，构建、安装并打开应用；不指定时用已启动的或最新的 iPhone
#   ./ios.sh deploy [设备]      # 构建、安装并打开到 iPhone；不指定时用第一台已配对的
#
# 真机需要已配对、已解锁并打开开发者模式。
# 环境变量 CONFIGURATION（Debug / Release）对所有操作有效。

set -euo pipefail

ROOT="${0:A:h}"
IOS="$ROOT/ios"
NAME="${0:t}"
ACTIONS=("build" "build device" "emulate" "deploy")

usage() {
    print -u2 "Usage: $NAME [build [device] | emulate [simulator] | deploy [device]]"
    exit 2
}

choose() {
    local PROMPT3="iOS: "
    select action in "${ACTIONS[@]}"; do
        [[ -n "$action" ]] && { print -r -- "$action"; return; }
    done
    exit 1
}

if (( $# == 0 )); then
    set -- ${(z)$(choose)}
fi
action="$1"
shift

case "$action" in
    build)
        (( $# <= 1 )) || usage
        "$IOS/build.sh" "${1:-simulator}"
        ;;
    emulate)
        (( $# <= 1 )) || usage
        "$IOS/emulate.sh" "$@"
        ;;
    deploy)
        (( $# <= 1 )) || usage
        "$IOS/deploy.sh" "$@"
        ;;
    *) usage ;;
esac
