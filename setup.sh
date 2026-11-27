#!/bin/zsh
#
# 安装构建和运行 Voiced 所需的环境，已经装好的会跳过：
#   - Xcode 命令行工具：Swift，用于 Mac 版和 core（缺少时打开系统安装窗口，装完后再运行一次）
#   - Xcode：只有 iOS 版需要，只能从 App Store 安装，这里只检查并提示
#   - Rust：用于 voiced 服务（有 Homebrew 时用 brew 安装，否则用 rustup）
#   - Claude Code：Run 模式用它执行句子，安装前会询问
# 之后运行 ./install.sh 安装 voiced 命令，再用 voiced service start 启动服务。
#
# Windows 上用 setup.bat。

set -euo pipefail

ROOT="${0:A:h}"

print "== Xcode command line tools"
if xcode-select -p &>/dev/null; then
    print "Already installed: $(xcode-select -p)"
else
    xcode-select --install || true
    print "Finish the installation in the window that opened, then run ${0:t} again."
    exit 1
fi

print "== Xcode (for the iOS app)"
if xcodebuild -version &>/dev/null; then
    print "Already installed: $(xcodebuild -version | head -1)"
else
    print "Not installed. The iOS app needs Xcode: install it from the App Store, open it once, then run"
    print "  sudo xcode-select -s /Applications/Xcode.app"
    print "The voiced service and the Mac app build without it."
fi

print "== Rust (for the voiced service)"
# A rustup installed earlier may not be on PATH in this shell yet.
[[ -x "$HOME/.cargo/bin/cargo" ]] && path=("$HOME/.cargo/bin" $path)
if command -v cargo &>/dev/null; then
    print "Already installed: $(cargo --version)"
elif command -v brew &>/dev/null; then
    brew install rust
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    path=("$HOME/.cargo/bin" $path)
fi
command -v cargo &>/dev/null || { print -u2 "Rust did not install."; exit 1; }

print "== Claude Code (for Run mode)"
[[ -x "$HOME/.local/bin/claude" ]] && path=("$HOME/.local/bin" $path)
if command -v claude &>/dev/null; then
    print "Already installed: $(command -v claude)"
else
    read -q "answer?Run mode carries sentences out with Claude Code. Install it? [y/N] " || answer=n
    print
    if [[ "$answer" == y ]]; then
        curl -fsSL https://claude.ai/install.sh | bash
    else
        print "Skipped. Type and Type and Return work without it."
    fi
fi

print
print "Ready. Next:"
print "  ./install.sh            install the voiced command"
print "  voiced service start    build and start the voiced service"
