#!/usr/bin/env bash
# Publishes a Glass release from this Mac.
#
# GitHub-hosted runners cannot build Glass: the app needs the macOS 27 SDK for
# APIs like swipeActionsContainer(), which no hosted runner ships. Releases are
# therefore produced locally, where build-mac-app.sh already builds and strictly
# verifies a signed app.
#
# Releases stay unsigned, so macOS quarantines the download once per version.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GLASS_RELEASE_REPO:-metalnakls/glass}"
VERSION_FILE="$ROOT_DIR/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "No VERSION file at $VERSION_FILE" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
    echo "VERSION is empty" >&2
    exit 1
fi

GLASS_VERSION="$VERSION" GLASS_SKIP_INSTALL=1 "$ROOT_DIR/Scripts/build-mac-app.sh" release

APP_DIR="$ROOT_DIR/.build/Xcode/Build/Products/Release/Glass.app"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

SIGN_UPDATE="$(find "$ROOT_DIR/.build/Xcode/SourcePackages" -type f -name sign_update -perm +111 2>/dev/null | head -1)"
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "Could not find sign_update. Run Scripts/build-mac-app.sh release to resolve Sparkle." >&2
    exit 1
fi

cd "$ROOT_DIR"
DIST="$ROOT_DIR/.build/release"
rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Glass.zip"

# The asset name is stable so the download button never needs updating.
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    SIGNATURE_LINE="$(printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN_UPDATE" "$ZIP" --ed-key-file -)"
else
    SIGNATURE_LINE="$("$SIGN_UPDATE" "$ZIP")"
fi
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGNATURE_LINE")"
if [[ -z "$ED_SIGNATURE" ]]; then
    echo "Could not read the EdDSA signature from sign_update output:" >&2
    echo "$SIGNATURE_LINE" >&2
    exit 1
fi

LENGTH="$(stat -f%z "$ZIP")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
TAG="v${VERSION}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/Glass.zip"

APPCAST="$DIST/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Glass Updates</title>
    <item>
      <title>Glass ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${LENGTH}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag
fi

gh release create "$TAG" "$ZIP" "$APPCAST" \
    --repo "$REPO" \
    --title "$VERSION" \
    --notes ""

echo ""
echo "Published Glass ${VERSION}"
echo "  $DOWNLOAD_URL"
