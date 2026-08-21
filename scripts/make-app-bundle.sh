#!/bin/bash
# Assembles noswoosh.app around the noswoosh binary. Builds the binary first
# unless --binary is given. Signing is opt-in: without an identity the bundle
# keeps swiftc's ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

BINARY=""
OUT_DIR="build"
IDENTITY="${NOSWOOSH_SIGN_IDENTITY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --sign) IDENTITY="$2"; shift 2 ;;
        *) echo "usage: make-app-bundle.sh [--binary <path>] [--out <dir>] [--sign <identity>]" >&2; exit 1 ;;
    esac
done

VERSION=$(sed -n 's/^let noswooshVersion = "\(.*\)"$/\1/p' noswoosh.swift)
if [ -z "$VERSION" ]; then
    echo "could not read noswooshVersion from noswoosh.swift" >&2
    exit 1
fi

BUILD_TMP=""
if [ -z "$BINARY" ]; then
    echo "==> Building noswoosh $VERSION"
    BUILD_TMP=$(mktemp -d)
    swiftc noswoosh.swift -O -o "$BUILD_TMP/noswoosh" \
        -F /System/Library/PrivateFrameworks -framework SkyLight
    BINARY="$BUILD_TMP/noswoosh"
fi

APP="$OUT_DIR/noswoosh.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/noswoosh"
chmod +x "$APP/Contents/MacOS/noswoosh"
sed "s/@VERSION@/$VERSION/g" scripts/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -f assets/icon-rounded.png ]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size assets/icon-rounded.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) assets/icon-rounded.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

if [ -n "$BUILD_TMP" ]; then rm -rf "$BUILD_TMP"; fi

if [ -n "$IDENTITY" ]; then
    echo "==> Codesigning with $IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/noswoosh"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "==> No signing identity (set NOSWOOSH_SIGN_IDENTITY or pass --sign); bundle is ad-hoc signed"
fi

echo "$APP"
