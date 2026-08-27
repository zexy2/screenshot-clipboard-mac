#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

bash -n "$PROJECT_DIR/Scripts/build.sh" "$PROJECT_DIR/Scripts/install.sh" "$PROJECT_DIR/Scripts/uninstall.sh"
/usr/bin/plutil -lint "$PROJECT_DIR/Resources/Info.plist"
/usr/bin/plutil -lint "$PROJECT_DIR/Resources/com.zekiakgul.screenshot-clipboard-helper-launcher.plist.in"
"$PROJECT_DIR/Scripts/build.sh"
/usr/bin/codesign --verify --verbose=2 "$PROJECT_DIR/build/Screenshot Clipboard.app"

echo "Checks passed."
