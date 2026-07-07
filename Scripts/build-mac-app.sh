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
XCODE_CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIGURATION:0:1}")${CONFIGURATION:1}"
DERIVED_DATA="$ROOT_DIR/.build/Xcode"

xcodebuild \
    -project "$ROOT_DIR/Apps/Glass/Glass.xcodeproj" \
    -scheme Glass \
    -configuration "$XCODE_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    build

APP_DIR="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/Glass.app"

echo "$APP_DIR"
