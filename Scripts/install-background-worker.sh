#!/bin/bash
# Installs only the Downloads worker for the current login user; never uses sudo.
set -euo pipefail
app="${2:-/Applications/Glass.app}"
label=tsmc.glass.downloads
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
case "${1:-install}" in
  uninstall)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    echo 'Glass Downloads worker removed.'
    exit 0 ;;
  install) ;;
  *) echo 'Usage: bash install-background-worker.sh [install|uninstall] [/Applications/Glass.app]' >&2; exit 64 ;;
esac
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == tsmc.glass ]]
worker="$app/Contents/Library/LoginItems/GlassWorker.app"
codesign --verify --deep --strict "$app"
# The downloaded release already has ad-hoc signatures. Refresh the helper's
# signature locally, preserving its Downloads-only sandbox entitlements, then
# reseal the parent after that nested-code change.
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$worker"
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$app"
codesign --verify --deep --strict "$app"
# This is the explicit local install step for the unsigned downloaded app.
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
"$app/Contents/MacOS/Glass" --use-background-launch-agent
mkdir -p "$(dirname "$plist")"
staging="$(mktemp "$(dirname "$plist")/.glass-worker.XXXXXX")"
trap 'rm -f "$staging"' EXIT
# PlistBuddy encodes paths as data, including spaces, rather than shell code.
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$staging"
/usr/libexec/PlistBuddy -c "Add :Label string $label" "$staging"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$staging"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $worker/Contents/MacOS/GlassWorker" "$staging"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$staging"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$staging"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 10' "$staging"
plutil -lint "$staging"
chmod 600 "$staging"
launchctl bootout "$domain/$label" 2>/dev/null || true
mv "$staging" "$plist"
launchctl enable "$domain/$label"
launchctl bootstrap "$domain" "$plist"
for ((attempt=0; attempt<20; attempt++)); do
    if launchctl print "$domain/$label" | grep -q 'state = running'; then
        sleep 2
        if launchctl print "$domain/$label" | grep -q 'state = running'; then
            "$app/Contents/MacOS/Glass" --enable-background-worker
            echo 'Glass Downloads worker installed and running.'
            exit 0
        fi
    fi
    sleep 1
done
launchctl print "$domain/$label" >&2
echo 'Worker failed to remain running; installation is not verified.' >&2
exit 1
