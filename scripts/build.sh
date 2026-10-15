#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Usage Bar.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -O \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$APP_DIR/Contents/MacOS/UsageBar"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# A stable certificate keeps the keychain "Always Allow" grant valid across rebuilds.
SIGN_IDENTITY="${SIGN_IDENTITY:-Usage Bar Signing}"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "warning: certificate \"$SIGN_IDENTITY\" not found; using ad-hoc signing" >&2
  codesign --force --sign - "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

echo "Built $APP_DIR"
