#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.build/Voiced.app"
EXECUTABLE="$APP/Contents/MacOS/Voiced"

if pgrep -f -- "$EXECUTABLE" >/dev/null; then
    print "Voiced is already running."
    exit 0
fi

if [[ ! -x "$EXECUTABLE" ]]; then
    "$ROOT/Scripts/build-app.sh"
fi

open "$APP"
print "Started Voiced."
