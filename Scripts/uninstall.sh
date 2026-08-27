#!/bin/bash
set -euo pipefail

APP_NAME="Screenshot Clipboard.app"
DEST_APP="$HOME/Applications/$APP_NAME"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.zekiakgul.screenshot-clipboard-helper-launcher.plist"
LABEL="com.zekiakgul.screenshot-clipboard-helper-launcher"
UID_VALUE="$(id -u)"

/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" "$LAUNCH_AGENT" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"
rm -rf "$DEST_APP"

echo "Uninstalled Screenshot Clipboard."
