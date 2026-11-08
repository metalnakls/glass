#!/bin/sh
set -eu
setup=$(mktemp -d "${TMPDIR:-/tmp}/glass-setup.XXXXXX")
trap 'rm -rf "$setup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 'https://metalnakls.github.io/glass/installers/52695056da3b22e2334a95cb3f1abca432c334cf72ae88337566012071bfeaea.sh' -o "$setup/install.sh"
printf '%s  %s\n' '52695056da3b22e2334a95cb3f1abca432c334cf72ae88337566012071bfeaea' "$setup/install.sh" | shasum -a 256 -c -
/bin/bash "$setup/install.sh" "$@"
