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
# plutil may append when replacing an array path on some macOS versions.
# Keep launchd arguments to exactly one executable path.
while /usr/bin/plutil -extract ProgramArguments.1 raw "$LAUNCH_AGENT" >/dev/null 2>&1; do
  /usr/bin/plutil -remove ProgramArguments.1 "$LAUNCH_AGENT"
done
/usr/bin/plutil -lint "$LAUNCH_AGENT"

/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" "$LAUNCH_AGENT" 2>/dev/null || true
bootstrapSucceeded=false
for attempt in 1 2 3; do
  if /bin/launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_AGENT" 2>/dev/null; then
    bootstrapSucceeded=true
    break
  fi
  /bin/sleep 1
done
if [ "$bootstrapSucceeded" != true ]; then
  echo "LaunchAgent bootstrap failed after 3 attempts." >&2
  exit 1
fi

echo "Installed: $DEST_APP"
echo "LaunchAgent: $LAUNCH_AGENT"
echo "macOS may ask for Desktop access once. Choose Allow."
