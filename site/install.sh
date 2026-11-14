#!/bin/sh
set -eu
setup=$(mktemp -d "${TMPDIR:-/tmp}/glass-setup.XXXXXX")
trap 'rm -rf "$setup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 'https://metalnakls.github.io/glass/installers/4e19491ed7c402241e915261efdda1f1bac6785140709c6046e25d9551ac2784.sh' -o "$setup/install.sh"
printf '%s  %s\n' '4e19491ed7c402241e915261efdda1f1bac6785140709c6046e25d9551ac2784' "$setup/install.sh" | shasum -a 256 -c -
/bin/bash "$setup/install.sh" "$@"
