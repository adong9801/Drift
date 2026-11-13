#!/bin/zsh
set -euo pipefail
ROOT=${0:a:h:h}
mkdir -p "$ROOT/.build"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/ModuleCache"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos15.4" \
  -o "$ROOT/.build/resource-check" "$ROOT/Tests/Resources/main.swift" \
  $(find "$ROOT/Sources" -name '*.swift' ! -name 'DriftApp.swift' | sort)
export DRIFT_DATA_DIR=$(mktemp -d -t drift-resources)
"$ROOT/.build/resource-check" "$ROOT/.build/performance-settings.png"
