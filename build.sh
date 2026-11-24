#!/bin/zsh
#
# 构建全部：macOS 应用、voiced 服务和 iOS 应用。
#
# 用法：
#   ./build.sh            # iOS 为模拟器版（无需签名）
#   ./build.sh device     # iOS 为真机版（用工程中的 Team 签名）
#
# 只构建一部分用 ./macos.sh build、./core.sh build、./ios.sh build。
# 构建服务不会重启正在运行的服务；要让新版本生效，运行 ./core.sh restart 或 voiced restart。

set -euo pipefail

ROOT="${0:A:h}"

case "${1:-simulator}" in
    sim|simulator) ios_target=simulator ;;
    device|iphone) ios_target=device ;;
    *)
        print -u2 "Usage: ${0:t} [device]"
        exit 2
        ;;
esac
(( $# <= 1 )) || { print -u2 "Usage: ${0:t} [device]"; exit 2; }

print "==> macOS"
"$ROOT/macos/Scripts/build-app.sh"

print "==> voiced service"
"$ROOT/core/build.sh"

print "==> iOS"
"$ROOT/ios/build.sh" "$ios_target"
