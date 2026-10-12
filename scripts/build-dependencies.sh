#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$ROOT/.dependencies"
WORK="$ROOT/.dependency-build"
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This project targets Apple Silicon. Build it on an arm64 Mac." >&2
    exit 1
fi
if [[ -f "$PREFIX/.versions" ]] && [[ "$(cat "$PREFIX/.versions")" == "libusb-1.0.30 libmtp-1.1.23 macOS-14" ]]; then
    echo "USB dependencies are already built."
    exit 0
fi
command -v pkg-config >/dev/null || { echo "Install pkg-config first: brew install pkg-config" >&2; exit 1; }
mkdir -p "$PREFIX" "$WORK"

download() {
    local url="$1" archive="$2" checksum="$3"
    if [[ ! -f "$archive" ]]; then curl --fail --location --retry 3 "$url" --output "$archive"; fi
    echo "$checksum  $archive" | shasum -a 256 --check
}

download "https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2" \
    "$WORK/libusb.tar.bz2" "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
download "https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz" \
    "$WORK/libmtp.tar.gz" "74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed"

export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0 -isysroot $SDKROOT"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0 -isysroot $SDKROOT -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
JOBS="$(sysctl -n hw.ncpu)"
tar -xf "$WORK/libusb.tar.bz2" -C "$WORK"
tar -xf "$WORK/libmtp.tar.gz" -C "$WORK"
(
    cd "$WORK/libusb-1.0.30"
    ./configure --prefix="$PREFIX" --disable-static --enable-shared
    make -j"$JOBS"
    make install
)
(
    cd "$WORK/libmtp-1.1.23"
    ./configure --prefix="$PREFIX" --disable-static --enable-shared --disable-mtpz --disable-doxygen
    make -j"$JOBS"
    make install
)
mkdir -p "$PREFIX/licenses"
cp "$WORK/libusb-1.0.30/COPYING" "$PREFIX/licenses/libusb-COPYING"
cp "$WORK/libmtp-1.1.23/COPYING" "$PREFIX/licenses/libmtp-COPYING"
echo "libusb-1.0.30 libmtp-1.1.23 macOS-14" > "$PREFIX/.versions"
echo "Built arm64 USB libraries for macOS 14 and later."
