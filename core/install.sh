#!/bin/zsh
#
# 安装 Voiced Input 服务：构建后注册为 launchd 用户代理，登录时自动启动，退出后自动重启。
# 服务一直等待 iPhone 版 Voiced 连接，把收到的每句话输入到当前光标处，不需要打开 Voiced 窗口。
# 再次运行会重新构建并重启服务。之后用仓库根目录的 vd 控制它（vd start / stop / restart）。
#
# 首次运行时系统会请求辅助功能权限：在 系统设置 → 隐私与安全性 → 辅助功能 中允许 VoicedInput。
# 日志：~/Library/Logs/VoicedInput.log
# 卸载：core/uninstall.sh

set -euo pipefail

ROOT="${0:A:h}"

"$ROOT/build.sh"
# Restart so the new build takes over.
"${ROOT:h}/vd" restart
