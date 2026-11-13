#!/bin/zsh
# Runs the real browser offscreen against the network. Shows no window, and
# keeps its session, history and block list in a scratch folder.
set -euo pipefail

ROOT=${0:a:h:h}
BIN="$ROOT/.build/smoke"
OUT="$ROOT/.build/shots"
mkdir -p "$OUT"

# Everything but the @main entry point, which the harness replaces. The old
# binary goes first: a build that fails must not quietly run last time's tests.
rm -f "$BIN"
swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macos15.4" \
  -o "$BIN" \
  "$ROOT/Tests/Smoke/main.swift" \
  $(find "$ROOT/Sources" -name '*.swift' ! -name 'DriftApp.swift' | sort) 2>&1 | grep -E " error: " || true

[[ -x "$BIN" ]] || { echo "smoke test did not compile"; exit 1; }

export DRIFT_DATA_DIR=$(mktemp -d -t drift-smoke)
"$BIN" "$OUT"
echo "shots: $OUT"
