#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/artifacts/macos/Dictator.app"
INSTALL_DIR="/Applications/Dictator.app"
START_ON_LOGIN="${1:-}"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT/scripts/Build-Mac.sh"
fi

rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

if [[ "$START_ON_LOGIN" == "--start-on-login" ]]; then
  PLIST="$HOME/Library/LaunchAgents/com.ransona.dictator.mac.plist"
  mkdir -p "$(dirname "$PLIST")"
  /usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :Label string com.ransona.dictator.mac" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /Applications/Dictator.app/Contents/MacOS/Dictator" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
fi

echo "Installed $INSTALL_DIR"
echo "Shortcut: Command+D"
echo "On first launch, macOS will ask for microphone permission. The shortcut and paste automation may require Accessibility permission in System Settings."
