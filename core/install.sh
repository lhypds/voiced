#!/bin/zsh
#
# 安装 Voiced Input 服务：构建后注册为 launchd 用户代理，登录时自动启动，退出后自动重启。
# 服务一直等待 iPhone 版 Voiced 连接，把收到的每句话输入到当前光标处，不需要打开 Voiced 窗口。
# 再次运行会重新构建并重启服务。
#
# 首次运行时系统会请求辅助功能权限：在 系统设置 → 隐私与安全性 → 辅助功能 中允许 VoicedInput。
# 日志：~/Library/Logs/VoicedInput.log
# 卸载：core/uninstall.sh

set -euo pipefail

ROOT="${0:A:h}"
LABEL="com.local.voiced.input"
EXECUTABLE="$ROOT/.build/VoicedInput.app/Contents/MacOS/VoicedInput"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/VoicedInput.log"
DOMAIN="gui/$(id -u)"

"$ROOT/build.sh"

mkdir -p "${PLIST:h}" "${LOG:h}"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

# Replace a running copy so the new build takes over.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

print "Installed $PLIST; the service is running and starts at login."
print "Log: $LOG"
