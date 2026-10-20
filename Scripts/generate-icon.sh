#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_PNG="$ROOT/.build/AppIcon-1024.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUTPUT="$ROOT/Support/AppIcon.icns"

mkdir -p "$ROOT/.build"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$ROOT/Scripts/generate-icon.swift" "$SOURCE_PNG"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$SOURCE_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "$OUTPUT" "$ICONSET"
print "Generated $OUTPUT"
