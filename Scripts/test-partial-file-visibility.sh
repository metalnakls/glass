#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/glass-partial-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
clang++ -std=c++20 -I "$ROOT_DIR/Apps/Glass" \
    "$ROOT_DIR/Tests/GlassNativeTests/PartialFileVisibilityTests.cpp" -o "$TEST_DIR/check"
"$TEST_DIR/check"
