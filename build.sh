#!/bin/zsh
# Builds .build/Drift.app. No Xcode project, same as Ante: swiftc over Sources/.
set -euo pipefail

ROOT=${0:a:h}
APP="$ROOT/.build/Drift.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# The icon is generated, not checked in as pixels: see Support/make-icon.swift.
[[ -f "$ROOT/Support/Drift.icns" ]] || swift "$ROOT/Support/make-icon.swift"
cp "$ROOT/Support/Drift.icns" "$APP/Contents/Resources/Drift.icns"

# -parse-as-library is required for @main to work outside a main.swift.
swiftc \
  -parse-as-library \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macos15.4" \
  -O \
  -o "$APP/Contents/MacOS/Drift" \
  $(find "$ROOT/Sources" -name '*.swift' | sort)

# Ad-hoc signature. Camera, microphone and location grants are tied to it, so
# macOS asks again after a rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
