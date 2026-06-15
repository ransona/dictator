#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/macos/DictatorMac"
ARTIFACTS_DIR="$ROOT/artifacts/macos"
APP_DIR="$ARTIFACTS_DIR/Dictator.app"

swift build --package-path "$PACKAGE_DIR" -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$PACKAGE_DIR/.build/release/Dictator" "$APP_DIR/Contents/MacOS/Dictator"
cp "$PACKAGE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/Dictator"

SIGNING_IDENTITY="${DICTATOR_CODESIGN_IDENTITY:-Dictator Local Code Signing}"
if security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY\""; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  echo "Warning: signing identity '$SIGNING_IDENTITY' not found; using ad-hoc signing."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"
