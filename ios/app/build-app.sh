#!/usr/bin/env bash
# Build DinoPoc.app for the iOS Simulator and optionally install + launch it.
# Usage: ./build-app.sh [run]
set -euo pipefail

TARGET=sim-arm64
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PREFIX="$ROOT/prefix/$TARGET"
POC="$ROOT/poc/out-$TARGET"
BUILD="$HERE/build"
APP="$BUILD/DinoPoc.app"
MIN_IOS=16.0
TRIPLE="arm64-apple-ios${MIN_IOS}-simulator"
SDKPATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$PREFIX/lib/gio/modules/pkgconfig"
CFLAGS="$(pkg-config --cflags gio-2.0 gee-0.8)"
LIBS="$(pkg-config --libs --static gio-2.0 gee-0.8 gdk-pixbuf-2.0 gioopenssl)"

rm -rf "$APP" && mkdir -p "$APP"

xcrun -sdk iphonesimulator swiftc \
  -target "$TRIPLE" \
  -import-objc-header "$HERE/bridge.h" \
  $(printf -- '-Xcc %s ' $CFLAGS) -Xcc -I"$POC" \
  "$HERE"/Sources/*.swift \
  -L "$POC" -ldinopoc -lxmpp-vala \
  $LIBS \
  -o "$APP/DinoPoc"

cp "$HERE/Info.plist" "$APP/Info.plist"
# CA bundle for OpenSSL certificate verification (from the build host).
if [ -f /etc/ssl/cert.pem ]; then
  cp /etc/ssl/cert.pem "$APP/cacert.pem"
fi
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "run" ]; then
  xcrun simctl boot "iPhone 17" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install booted "$APP"
  xcrun simctl launch booted im.dino.ios.poc
fi
