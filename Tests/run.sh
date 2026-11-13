#!/bin/zsh
# Compiles and runs the logic checks. No WebKit, no UI, so it is quick.
set -euo pipefail

ROOT=${0:a:h:h}
BIN=$(mktemp -d)/driftcheck

swiftc -swift-version 5 -O -o "$BIN" \
  "$ROOT/Tests/main.swift" \
  "$ROOT"/Sources/Core/*.swift 2>/dev/null

"$BIN"
