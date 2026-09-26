#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
SIGN_IDENTITY="${GLASS_CODESIGN_IDENTITY:-DEVELOPMENT_SIGNING_IDENTITY}"
INSTALL_DIR="/Applications/Glass.app"
BACKUP_PREFIX="/Applications/Glass.app.backup-"
SYSTEM_SIGN_IDENTITY="DEVELOPMENT_SIGNING_IDENTITY"
INSTALL_BACKUP=""
INSTALL_STARTED=0

case "$CONFIGURATION" in
    debug|release) ;;
    cleanup-backups)
        find /Applications -maxdepth 1 -type d -name 'Glass.app.backup-*' -exec rm -rf -- {} +
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

restore_install() {
    if [[ "$INSTALL_STARTED" -eq 1 ]]; then
        if [[ -n "$INSTALL_BACKUP" && -d "$INSTALL_BACKUP" ]]; then
            echo "Install failed; restoring the previous app from $INSTALL_BACKUP" >&2
            find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
            ditto "$INSTALL_BACKUP" "$INSTALL_DIR"
            codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR"
        elif [[ -d "$INSTALL_DIR" ]]; then
            echo "Install failed; removing the incomplete first install at $INSTALL_DIR" >&2
            rm -rf -- "$INSTALL_DIR"
        fi
    fi
}

on_exit() {
    local status=$?

    if [[ "$status" -ne 0 ]]; then
        restore_install || echo "Could not fully restore $INSTALL_DIR; preserved backup: $INSTALL_BACKUP" >&2
    fi
    trap - EXIT
    exit "$status"
}
trap on_exit EXIT

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
if [[ ! -d "$APP_DIR" ]]; then
    echo "Build completed without the expected app bundle: $APP_DIR" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR" 2>&1

if [[ -L "$INSTALL_DIR" || ( -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ) ]]; then
    echo "Install destination exists but is not an app directory: $INSTALL_DIR" >&2
    exit 1
fi

if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_PATH="${BACKUP_PREFIX}$(date '+%Y%m%d-%H%M%S')"
    BACKUP_SUFFIX=0
    while [[ -e "$BACKUP_PATH" ]]; do
        BACKUP_SUFFIX=$((BACKUP_SUFFIX + 1))
        BACKUP_PATH="${BACKUP_PREFIX}$(date '+%Y%m%d-%H%M%S')-${BACKUP_SUFFIX}"
    done
    ditto "$INSTALL_DIR" "$BACKUP_PATH"
    INSTALL_BACKUP="$BACKUP_PATH"
fi

INSTALL_STARTED=1
mkdir -p "$INSTALL_DIR"
ditto "$APP_DIR" "$INSTALL_DIR"
codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR"
codesign --display --verbose=4 "$INSTALL_DIR" 2>&1
INSTALL_STARTED=0

echo "$APP_DIR"
