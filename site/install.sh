#!/bin/sh
set -eu
setup=$(mktemp -d "${TMPDIR:-/tmp}/glass-setup.XXXXXX")
trap 'rm -rf "$setup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 'https://metalnakls.github.io/glass/installers/8349cab735b5b96f2ba4a41a0a9c696d2bf1585334d641623c62cbcd93677036.sh' -o "$setup/install.sh"
printf '%s  %s\n' '8349cab735b5b96f2ba4a41a0a9c696d2bf1585334d641623c62cbcd93677036' "$setup/install.sh" | shasum -a 256 -c -
/bin/bash "$setup/install.sh" "$@"
