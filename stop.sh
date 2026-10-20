#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h}"
EXECUTABLE="$ROOT/.build/Voiced.app/Contents/MacOS/Voiced"
PID_OUTPUT="$(pgrep -f -- "$EXECUTABLE" 2>/dev/null || true)"

if [[ -z "$PID_OUTPUT" ]]; then
    print "Voiced is not running."
    exit 0
fi

PIDS=("${(@f)PID_OUTPUT}")
kill "${PIDS[@]}"
print "Stopped Voiced."
