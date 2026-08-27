#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Screenshot Clipboard.app"
SOURCE_APP="$PROJECT_DIR/build/$APP_NAME"
DEST_APP="$HOME/Applications/$APP_NAME"
APP_EXECUTABLE="$DEST_APP/Contents/MacOS/ScreenshotClipboard"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/com.zekiakgul.screenshot-clipboard-helper-launcher.plist"
LABEL="com.zekiakgul.screenshot-clipboard-helper-launcher"
UID_VALUE="$(id -u)"

"$PROJECT_DIR/Scripts/build.sh"
mkdir -p "$HOME/Applications" "$LAUNCH_AGENTS_DIR"

ditto "$SOURCE_APP" "$DEST_APP"
cp "$PROJECT_DIR/Resources/com.zekiakgul.screenshot-clipboard-helper-launcher.plist.in" "$LAUNCH_AGENT"
/usr/bin/plutil -replace ProgramArguments.0 -string "$APP_EXECUTABLE" "$LAUNCH_AGENT"
/usr/bin/plutil -lint "$LAUNCH_AGENT"

/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" "$LAUNCH_AGENT" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_AGENT"

echo "Installed: $DEST_APP"
echo "LaunchAgent: $LAUNCH_AGENT"
echo "macOS may ask for Desktop access once. Choose Allow."
