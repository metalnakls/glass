#!/bin/sh
set -eu
setup=$(mktemp -d "${TMPDIR:-/tmp}/glass-setup.XXXXXX")
trap 'rm -rf "$setup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 'https://metalnakls.github.io/glass/installers/89764b5da4896cec0c9a8f02849fb12edd92621f036a4f8bf509f77049a872aa.sh' -o "$setup/install.sh"
printf '%s  %s\n' '89764b5da4896cec0c9a8f02849fb12edd92621f036a4f8bf509f77049a872aa' "$setup/install.sh" | shasum -a 256 -c -
/bin/bash "$setup/install.sh" "$@"
