#!/bin/bash
# Build a pinned, self-contained iperf3 helper; no Homebrew libraries at runtime.
set -euo pipefail
APP_BUNDLE="${1:?Usage: bundle-iperf3.sh app-bundle [signing-identity]}"
SIGNING_IDENTITY="${2:--}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$SCRIPT_DIR/../.build/iperf3-3.21"
ARCHIVE="$CACHE/iperf-3.21.tar.gz"
EXPECTED_SHA256=656e4405ebd620121de7ceca3eaf43a88f79ea1b857d041a6a0b1314801acdd8
mkdir -p "$CACHE" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources/ThirdParty"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 3 https://downloads.es.net/pub/iperf/iperf-3.21.tar.gz -o "$ARCHIVE"
fi
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "iperf3 source checksum mismatch" >&2
    exit 1
fi
# Build both slices so the helper works for either Xcode app architecture.
for ARCH in arm64 x86_64; do
    BUILD="$CACHE/$ARCH"
    if [ ! -x "$BUILD/src/iperf3" ]; then
        mkdir -p "$BUILD"
        tar -xzf "$ARCHIVE" --strip-components=1 -C "$BUILD"
        (
            cd "$BUILD"
            MACOSX_DEPLOYMENT_TARGET=13.0 CFLAGS="-O2 -arch $ARCH" LDFLAGS="-arch $ARCH" \
                ./configure --host="$ARCH-apple-darwin" --disable-shared --enable-static --without-openssl > configure-build.log 2>&1
            make -j 4 > make-build.log 2>&1
        )
    fi
done
lipo -create "$CACHE/arm64/src/iperf3" "$CACHE/x86_64/src/iperf3" -output "$APP_BUNDLE/Contents/Helpers/iperf3"
cp "$CACHE/arm64/LICENSE" "$APP_BUNDLE/Contents/Resources/ThirdParty/iperf3-LICENSE.txt"
# Fail packaging if a future build accidentally introduces an external runtime dependency.
if otool -L "$APP_BUNDLE/Contents/Helpers/iperf3" | grep -E '/opt/|/usr/local/|@rpath'; then
    echo "iperf3 must not depend on Homebrew or other external libraries" >&2
    exit 1
fi
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/Helpers/iperf3"
