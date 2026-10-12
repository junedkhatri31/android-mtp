#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash scripts/build-dependencies.sh
export MTP_DEPENDENCY_PREFIX="$ROOT/.dependencies"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$ROOT/dist/Android MTP.app"
if [[ -d "$APP" ]]; then
    # Only replace this script's generated application bundle.
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN/AndroidMTP" "$APP/Contents/MacOS/AndroidMTP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Licenses/* "$APP/Contents/Resources/Licenses/"
cp LICENSE "$APP/Contents/Resources/Licenses/AndroidMTP-MIT"
cp .dependencies/licenses/* "$APP/Contents/Resources/Licenses/"
swift scripts/generate-icon.swift "$APP/Contents/Resources"
python3 scripts/bundle-libraries.py "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/AndroidMTP-arm64.zip"
echo "Built $APP"
echo "Run: open \"$APP\""
