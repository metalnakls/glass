#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
REVISION="$(tr -d '[:space:]' < "$ROOT_DIR/Vendor/transmission/REVISION")"
SOURCE_DIR="$ROOT_DIR/Vendor/transmission/source"
BUILD_DIR="$ROOT_DIR/.build/libtransmission/$CONFIGURATION/build"
INSTALL_DIR="$ROOT_DIR/.build/libtransmission/$CONFIGURATION/install"
MERGED_LIB="$INSTALL_DIR/lib/libGlassTransmission.a"

mkdir -p "$ROOT_DIR/Vendor/transmission" "$BUILD_DIR" "$INSTALL_DIR/lib"

if [ ! -d "$SOURCE_DIR/.git" ]; then
    rm -rf "$SOURCE_DIR"
    git clone https://github.com/transmission/transmission.git "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --depth 1 origin "$REVISION"
git -C "$SOURCE_DIR" checkout --detach "$REVISION"
git -C "$SOURCE_DIR" submodule update --init --recursive

if [ "$CONFIGURATION" = "Release" ]; then
    CMAKE_BUILD_TYPE="Release"
else
    CMAKE_BUILD_TYPE="Debug"
fi

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DENABLE_CLI=OFF \
    -DENABLE_DAEMON=OFF \
    -DENABLE_GTK=OFF \
    -DENABLE_MAC=OFF \
    -DENABLE_QT=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_UTILS=OFF \
    -DENABLE_NLS=OFF \
    -DINSTALL_DOC=OFF \
    -DINSTALL_WEB=OFF \
    -DREBUILD_WEB=OFF \
    -DUSE_SYSTEM_DEFAULT=OFF \
    -DWITH_CRYPTO=ccrypto

cmake --build "$BUILD_DIR" --target transmission --config "$CMAKE_BUILD_TYPE"

STATIC_LIB_LIST="$BUILD_DIR/static-libraries.list"
find "$BUILD_DIR" -name '*.a' -type f | sort > "$STATIC_LIB_LIST"
if [ ! -s "$STATIC_LIB_LIST" ]; then
    echo "No libtransmission static libraries were produced." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR/lib"
rm -f "$MERGED_LIB"
xargs /usr/bin/libtool -static -o "$MERGED_LIB" < "$STATIC_LIB_LIST"

echo "$MERGED_LIB"
