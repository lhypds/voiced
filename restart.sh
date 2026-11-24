#!/bin/zsh
#
# 全部重新构建并重启：先运行 ./build.sh（macOS 应用、voiced 服务、iOS 应用），
# 再重启 voiced 服务（保留当前文件夹）和 Mac 版，让它们用上新构建。
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
