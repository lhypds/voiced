#!/bin/zsh
#
# 停止并移除 core/install.sh 安装的 Voiced Input 服务（与 vd stop 相同）。构建产物和日志保留。

set -euo pipefail

"${0:A:h:h}/vd" stop
