#!/bin/zsh
#
# 停止并移除 core/install.sh 安装的 Voiced Input 服务。构建产物和日志保留。

set -euo pipefail

LABEL="com.local.voiced.input"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -e "$PLIST" ]]; then
    rm -f "$PLIST"
    print "Removed $PLIST"
else
    print "Voiced Input is not installed."
fi
