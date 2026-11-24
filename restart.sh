#!/bin/zsh
#
# 全部重新构建并重启：先运行 ./build.sh（macOS 应用、voiced 服务、iOS 应用），
# 再重启 voiced 服务（保留当前文件夹）和 Mac 版，最后重新安装并打开 iPhone 上的 iOS 版，
# 让它们都用上新构建。iPhone 未连接时只提示，不影响前面的结果。
#
# 用法：
#   ./restart.sh            # iOS 构建模拟器版
#   ./restart.sh device     # iOS 构建真机版（传给 build.sh）

set -euo pipefail

ROOT="${0:A:h}"

"$ROOT/build.sh" "$@"

# voiced restart without a folder would go back to the home folder: keep the one in use.
folder="$(defaults read com.local.voiced.input workFolder 2>/dev/null || print "$HOME")"
[[ -d "$folder" ]] || folder="$HOME"
print "==> voiced service"
"$ROOT/voiced" restart "$folder"

print "==> Mac app"
"$ROOT/voiced" restart macos

print "==> iPhone"
"$ROOT/voiced" restart ios device || print -u2 "The iPhone was not updated: connect and unlock it, then run ./voiced restart ios device."
