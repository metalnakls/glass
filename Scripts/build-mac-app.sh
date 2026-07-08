#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
SIGN_IDENTITY="${GLASS_CODESIGN_IDENTITY:-}"

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

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning |
            awk -F '"' '/Apple Development:/ { print $2; exit }'
    )"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Apple Development signing identity found. Set GLASS_CODESIGN_IDENTITY explicitly." >&2
    exit 65
fi

xcodebuild \
    -project "$ROOT_DIR/Apps/Glass/Glass.xcodeproj" \
    -scheme Glass \
    -configuration "$XCODE_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    build

APP_DIR="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/Glass.app"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
