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
DMG_ROOT="$(mktemp -d "$ROOT/.build/dmg-root.XXXXXX")"
trap 'rm -rf "$DMG_ROOT"' EXIT
ditto "$APP" "$DMG_ROOT/Android MTP.app"
ln -s /Applications "$DMG_ROOT/Applications"
cp docs/INSTALL.md "$DMG_ROOT/Read Me.txt"
hdiutil create -volname "Android MTP" -srcfolder "$DMG_ROOT" -fs HFS+ \
    -format UDZO -ov "$ROOT/dist/AndroidMTP-arm64.dmg"
cp .dependency-build/libmtp.tar.gz dist/libmtp-1.1.23.tar.gz
cp .dependency-build/libusb.tar.bz2 dist/libusb-1.0.30.tar.bz2
(
    cd "$ROOT/dist"
    shasum -a 256 AndroidMTP-arm64.dmg AndroidMTP-arm64.zip \
        libmtp-1.1.23.tar.gz libusb-1.0.30.tar.bz2 > SHA256SUMS.txt
)
echo "Built $APP"
echo "Installer: $ROOT/dist/AndroidMTP-arm64.dmg"
echo "Run: open \"$APP\""
