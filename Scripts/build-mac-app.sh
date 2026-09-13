#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
SIGN_IDENTITY="${GLASS_CODESIGN_IDENTITY:-919F9538E1E91B7C10FD2556CC9030B76ED39E58}"
INSTALL_DIR="/Applications/Glass.app"
BACKUP_PREFIX="/Applications/Glass.app.backup-"
SYSTEM_SIGN_IDENTITY="919F9538E1E91B7C10FD2556CC9030B76ED39E58"

case "$CONFIGURATION" in
    debug|release) ;;
    cleanup-backups)
        find /Applications -maxdepth 1 -name 'Glass.app.backup-*' -exec rm -rf {} +
        exit 0
        ;;
    *)
        echo "usage: $0 [debug|release|cleanup-backups]" >&2
        exit 64
        ;;
esac

if [ "$SIGN_IDENTITY" != "$SYSTEM_SIGN_IDENTITY" ]; then
    echo "GLASS_CODESIGN_IDENTITY must be $SYSTEM_SIGN_IDENTITY for local development signing." >&2
    exit 65
fi

AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
if ! grep -Fq "$SIGN_IDENTITY " <<< "$AVAILABLE_IDENTITIES"; then
    echo "Required Apple Development signing identity is unavailable: $SIGN_IDENTITY" >&2
    exit 65
fi

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
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [ -d "$INSTALL_DIR" ]; then
    BACKUP_PATH="${BACKUP_PREFIX}$(date '+%Y%m%d-%H%M%S')"
    ditto "$INSTALL_DIR" "$BACKUP_PATH"
fi

ditto "$APP_DIR" "$INSTALL_DIR"
codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR"

echo "$APP_DIR"
