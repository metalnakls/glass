#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
SIGN_IDENTITY="${GLASS_CODESIGN_IDENTITY:--}"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

cd "$ROOT_DIR"
swift build --product GlassMac -c "$CONFIGURATION"
BIN_DIR="$(swift build --product GlassMac -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="$ROOT_DIR/.build/Glass.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/GlassMac" "$MACOS_DIR/GlassMac"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT_DIR/Resources/Glass.entitlements" "$APP_DIR"

echo "$APP_DIR"
