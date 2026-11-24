#!/bin/zsh
#
# 停止并移除 core/install.sh 安装的 voiced 服务（与 voiced stop 相同）。构建产物和日志保留。

set -euo pipefail

"${0:A:h:h}/voiced" stop
