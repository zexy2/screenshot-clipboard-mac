#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/Screenshot Clipboard.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/ScreenshotClipboard"

rm -rf "$APP_DIR"
mkdir -p "$(dirname -- "$EXECUTABLE")"

/usr/bin/swiftc \
  -warnings-as-errors \
  -O \
  -framework AppKit \
  -framework Foundation \
  -framework ImageIO \
  -framework ApplicationServices \
  -Xlinker -weak_framework \
  -Xlinker Translation \
  -framework Vision \
  -o "$EXECUTABLE" \
  "$PROJECT_DIR/Sources/ScreenshotClipboard"/*.swift

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

/usr/bin/codesign \
  --force \
  --sign - \
  --requirements '=designated => identifier "com.zekiakgul.screenshot-clipboard"' \
  "$APP_DIR"

echo "Built: $APP_DIR"
