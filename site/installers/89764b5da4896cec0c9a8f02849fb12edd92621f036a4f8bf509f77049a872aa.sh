#!/bin/bash
# Generated from a published release. Uses only tools shipped with macOS.
set -euo pipefail
version='11'
archive_hash='b65590669fe7c700b00c310a05c9725f1639516cded8453dad6a34a140086c26'
worker_hash='9858506ddca88e670e9037a370f71db38d0949683ea00adc403e2263fb567619'
archive_api='https://api.github.com/repos/metalnakls/glass/releases/assets/733337652'
worker_api='https://api.github.com/repos/metalnakls/glass/releases/assets/733337646'
app=/Applications/Glass.app
local_release=''
verify_only=false
while (($#)); do
    case "$1" in
        --release-dir) local_release="$2"; shift 2 ;;
        --verify-only) verify_only=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 64 ;;
    esac
done
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Glass requires an Apple silicon Mac.' >&2; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 27 ]] || { echo 'Glass requires macOS 27 or later.' >&2; exit 1; }
cache="$HOME/Library/Caches/Glass-Setup/$version"
mkdir -p "$cache"
lock="$cache/install.lock"
if ! mkdir "$lock" 2>/dev/null; then
    previous=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ "$previous" =~ ^[0-9]+$ ]] && kill -0 "$previous" 2>/dev/null; then
        echo 'Another Glass installation is running.' >&2; exit 1
    fi
    rm -rf "$lock"
    mkdir "$lock"
fi
printf '%s\n' "$$" > "$lock/pid"
stage=$(mktemp -d "${TMPDIR:-/tmp}/glass-install.XXXXXX")
backup=''
changed=false
had_app=false
had_worker=false
was_running=false
plist="$HOME/Library/LaunchAgents/tsmc.glass.downloads.plist"
domain="gui/$(id -u)"
finish() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status -ne 0 && "$changed" == true ]]; then
        echo 'Installation failed; restoring the previous app.' >&2
        launchctl bootout "$domain/tsmc.glass.downloads" 2>/dev/null || true
        find "$app" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        if [[ "$had_app" == true ]]; then ditto "$backup/Glass.app" "$app"; else rmdir "$app"; fi
        if [[ "$had_worker" == true ]]; then
            cp "$backup/worker.plist" "$plist"
            launchctl bootstrap "$domain" "$plist" || true
        else
            rm -f "$plist"
        fi
        if [[ "$had_app" == true && "$was_running" == true ]]; then open "$app" || true; fi
    fi
    rm -rf "$stage" "$lock"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
fetch() {
    local name="$1" expected="$2" api="$3" file="$cache/$1" url
    if [[ -n "$local_release" ]]; then
        [[ "$(hash "$local_release/$name")" == "$expected" ]] || { echo "Checksum mismatch: $name" >&2; return 1; }
        cp "$local_release/$name" "$file"
    fi
    if [[ -f "$file" && "$(hash "$file")" == "$expected" ]]; then return; fi
    for url in "$api" "https://github.com/metalnakls/glass/releases/download/v$version/$name"; do
        if curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 60 --retry 1 --retry-all-errors \
            -H 'Accept: application/octet-stream' "$url" -o "$file.part"; then
            if [[ "$(hash "$file.part")" == "$expected" ]]; then mv "$file.part" "$file"; return; fi
            echo "Checksum mismatch: $name" >&2
        fi
    done
    echo 'Download failed. Rerun the same command; verified downloads are retained.' >&2
    return 1
}
printf 'Downloading and verifying Glass %s…\n' "$version"
fetch Glass.zip "$archive_hash" "$archive_api"
fetch install-background-worker.sh "$worker_hash" "$worker_api"
ditto -x -k "$cache/Glass.zip" "$stage"
new="$stage/Glass.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$new/Contents/Info.plist")" == tsmc.glass ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$new/Contents/Info.plist")" == "$version" ]]
codesign --verify --deep --strict "$new"
if [[ "$verify_only" == true ]]; then echo "Glass $version verified; installation unchanged."; exit 0; fi
[[ ! -L "$app" && ( ! -e "$app" || -d "$app" ) ]] || { echo 'Unsafe app destination.' >&2; exit 1; }
[[ -w /Applications && ( ! -e "$app" || -w "$app" ) ]] || { echo 'This account cannot replace /Applications/Glass.app.' >&2; exit 1; }
# AppKit termination saves normal application state without scripting Finder.
running_before=$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("tsmc.glass").count')
[[ "$running_before" == 0 ]] || was_running=true
/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("tsmc.glass"); for (var i=0; i<apps.count; i++) { apps.objectAtIndex(i).terminate; }' >/dev/null
for ((i=0; i<20; i++)); do
    running=$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationsWithBundleIdentifier("tsmc.glass").count')
    [[ "$running" == 0 ]] && break
    sleep 1
done
[[ "$running" == 0 ]] || { echo 'Glass could not close. Finish its open dialog, then rerun this command.' >&2; exit 1; }
backup_root="$HOME/Library/Application Support/Glass/InstallBackups"
mkdir -p "$backup_root"
backup=$(mktemp -d "$backup_root/install.XXXXXX")
if [[ -d "$app" ]]; then had_app=true; ditto "$app" "$backup/Glass.app"; fi
if [[ -f "$plist" ]]; then had_worker=true; cp "$plist" "$backup/worker.plist"; fi
launchctl bootout "$domain/tsmc.glass.downloads" 2>/dev/null || true
changed=true
mkdir -p "$app"
find "$app" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
ditto "$new" "$app"
codesign --verify --deep --strict "$app"
/bin/bash "$cache/install-background-worker.sh" install "$app"
changed=false
open "$app"
printf '\nGlass %s and its background worker are installed.\nBackup: %s\n' "$version" "$backup"
