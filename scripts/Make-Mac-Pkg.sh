#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/artifacts/macos/Dictator.app"
PKG_DIR="$ROOT/artifacts/pkg"
PKG_PATH="$PKG_DIR/Dictator-macOS.pkg"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT/scripts/Build-Mac.sh"
fi

mkdir -p "$PKG_DIR"
pkgbuild \
  --component "$APP_DIR" \
  --install-location /Applications \
  --identifier com.ransona.dictator.mac \
  --version 0.1.0 \
  "$PKG_PATH"

echo "Built $PKG_PATH"
