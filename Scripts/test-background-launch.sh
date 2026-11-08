#!/usr/bin/env bash
set -euo pipefail
app="${1:-/Applications/Glass.app}"
worker="$app/Contents/Library/LoginItems/GlassWorker.app"
[[ "$(plutil -extract CFBundleIdentifier raw "$worker/Contents/Info.plist")" == "tsmc.glass.worker" ]]
[[ "$(plutil -extract LSBackgroundOnly raw "$worker/Contents/Info.plist")" == true ]]
for key in CFBundleDocumentTypes CFBundleURLTypes; do
    if plutil -extract "$key" xml1 -o /dev/null "$worker/Contents/Info.plist" >/dev/null 2>&1; then
        echo "Worker claims a document or URL handler" >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$app"
result="$("$worker/Contents/MacOS/GlassWorker" --background-worker-self-test)"
printf '%s\n' "$result"
[[ "$result" == *"Worker rename, ghost icon, byte preservation, and prohibited activation passed:"* ]]
