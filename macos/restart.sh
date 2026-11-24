#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h}"

# Rebuild the app bundle so the restarted app picks up source changes.
"$ROOT/Scripts/build-app.sh"
"$ROOT/stop.sh"
"$ROOT/start.sh"
