#!/bin/zsh
set -euo pipefail
ROOT=${0:a:h:h}
SOURCE_ROOT=${DRIFT_TEST_SOURCES:-$ROOT/Sources}
CHECK="$ROOT/.build/LaunchCheck"
APP="$CHECK/DriftLinkCheck.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap '"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true' EXIT
mkdir -p "$APP/Contents/MacOS" "$CHECK/profile"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/ModuleCache"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.prototype.drift.launchcheck' "$APP/Contents/Info.plist"
python3 - "$SOURCE_ROOT/DriftApp.swift" "$CHECK/DriftApp.swift" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
needle = 'func applicationDidFinishLaunching(_ notification: Notification) {'
assert source.count(needle) == 1
Path(sys.argv[2]).write_text(source.replace(needle, needle + '\n        MainActor.assumeIsolated { LinkProbe.start() }'))
PY
swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macos15.4" \
  -o "$APP/Contents/MacOS/Drift" "$CHECK/DriftApp.swift" "$ROOT/Tests/Launch/Probe.swift" \
  $(find "$SOURCE_ROOT" -name '*.swift' ! -name 'DriftApp.swift' | sort)
codesign --force --sign - "$APP"
PROFILE=$(mktemp -d "$CHECK/profile/run.XXXXXX")
open -n -g -a "$APP" --env "DRIFT_DATA_DIR=$PROFILE" \
  --stdout "$PROFILE/stdout.txt" --stderr "$PROFILE/stderr.txt" 'https://example.com/#drift-cold'
python3 - "$PROFILE" <<'PY'
import json, sys, time
from pathlib import Path
profile = Path(sys.argv[1])
report = profile / 'launch-result.json'
for _ in range(45):
    if report.exists():
        results = json.loads(report.read_text())
        for result in results:
            print(('ok' if result['passed'] else 'FAIL') + ' ' + result['name'])
        print('Launch report: ' + str(report))
        sys.exit(0 if all(r['passed'] for r in results) else 1)
    time.sleep(1)
print('FAIL app did not finish the external-link checks; logs: ' + str(profile))
sys.exit(1)
PY
