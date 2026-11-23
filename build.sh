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

# Signed with the "Drift Local Signing" certificate when this Mac has one
# (Support/make-signing-cert.sh makes it): every build then carries the same
# signature, so what was granted to Drift (Accessibility, camera, microphone,
# location) carries over to the next. Otherwise ad-hoc, which macOS takes for
# a new app after each rebuild, so it asks again.
IDENTITY="Drift Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "built: $APP"
