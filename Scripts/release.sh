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

# Resolve the EdDSA private key. Order: explicit env, then the Keychain.
# The key lives in the login keychain, never as plaintext in the repo or a dotfile.
KEYCHAIN_SERVICE="https://sparkle-project.org"
KEYCHAIN_ACCOUNT="ed25519"

resolve_private_key() {
    if [ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]; then
        printf '%s' "$SPARKLE_PRIVATE_ED_KEY"
        return 0
    fi
    security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
}

PRIVATE_KEY="$(resolve_private_key || true)"
if [ -z "$PRIVATE_KEY" ]; then
    echo "No Sparkle EdDSA private key found." >&2
    echo "Looked for keychain item -a $KEYCHAIN_ACCOUNT -s $KEYCHAIN_SERVICE" >&2
    echo "or SPARKLE_PRIVATE_ED_KEY in the environment." >&2
    exit 1
fi

# Derive the public key half from the private seed and refuse to publish a
# release Sparkle would reject. A wrong key fails silently at install time,
# which is far worse than a failed release.
verify_key_matches_app() {
    local app_pub seed_file priv_der pub_der derived
    app_pub="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
    [ -n "$app_pub" ] || app_pub="$(sed -n 's|.*<string>$(SPARKLE_PUBLIC_ED_KEY)</string>.*|vKl2Nb7sR021uAXfeWPvh/naGAsQuLPKh/2FsMWYkV0=|p' "$ROOT_DIR/Scripts/build-mac-app.sh" | head -1)"

    seed_file="$(mktemp)"; priv_der="$(mktemp)"; pub_der="$(mktemp)"
    printf '%s' "$PRIVATE_KEY" | base64 -d > "$seed_file" 2>/dev/null || true
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20' > "$priv_der"
    cat "$seed_file" >> "$priv_der"
    openssl pkey -inform DER -in "$priv_der" -pubout -outform DER -out "$pub_der" 2>/dev/null || true
    derived="$(tail -c 32 "$pub_der" 2>/dev/null | base64)"
    rm -f "$seed_file" "$priv_der" "$pub_der"

    if [ -z "$derived" ]; then
        echo "Could not derive a public key from the private key." >&2
        return 1
    fi
    if [ "$derived" != "$app_pub" ]; then
        echo "Sparkle private key does NOT match the public key in the app." >&2
        echo "Publishing now would produce an update Sparkle refuses to install." >&2
        return 1
    fi
    echo "Sparkle key verified against the app's public key."
}

verify_key_matches_app

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

SIGNATURE_LINE="$(printf '%s' "$PRIVATE_KEY" | "$SIGN_UPDATE" "$ZIP" --ed-key-file -)"
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

# Publish near the start of an allowed even minute, leaving upload time within it.
while :; do
    DELIVERY_MINUTE="$(date +%M)"
    DELIVERY_SECOND="$(date +%S)"
    if (( 10#$DELIVERY_MINUTE % 2 == 0 && 10#$DELIVERY_MINUTE != 30 && 10#$DELIVERY_MINUTE != 50 && 10#$DELIVERY_SECOND <= 10 )); then
        break
    fi
    sleep 1
done

gh release create "$TAG" "$ZIP" "$APPCAST" \
    --repo "$REPO" \
    --title "$VERSION" \
    --notes ""

echo ""
echo "Published Glass ${VERSION}"
echo "  $DOWNLOAD_URL"
