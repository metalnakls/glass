#!/usr/bin/env bash
# Native integration check; run outside the sandbox in a logged-in macOS session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/glass-background-launch.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Probe.app/Contents/MacOS"
cat > "$FIXTURE/Probe.app/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tsmc.glass.launch-test.$(basename "$FIXTURE")</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -swift-version 6 -parse-as-library \
    "$ROOT/Sources/GlassRemoteUI/Support/GlassBackgroundApplication.swift" \
    "$ROOT/Tests/Fixtures/BackgroundLaunch/Fixture.swift" \
    -o "$FIXTURE/Probe.app/Contents/MacOS/Probe"
codesign --force --sign - "$FIXTURE/Probe.app"
swiftc -swift-version 6 -parse-as-library "$ROOT/Tests/Fixtures/BackgroundLaunch/Driver.swift" -o "$FIXTURE/Driver"
"$FIXTURE/Driver" "$FIXTURE"
