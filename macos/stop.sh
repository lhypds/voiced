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
# Wait for the process to exit: open run against an app that is still quitting fails with
# LaunchServices error -600, so restart.sh would leave Voiced stopped.
for _ in {1..50}; do
    pgrep -f -- "$EXECUTABLE" >/dev/null || break
    sleep 0.1
done
if pgrep -f -- "$EXECUTABLE" >/dev/null; then
    print -u2 "Voiced did not stop."
    exit 1
fi
print "Stopped Voiced."
