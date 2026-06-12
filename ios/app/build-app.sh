#!/usr/bin/env bash
# Build Dino.app (SwiftUI shell + full libdino core) for the iOS Simulator
# and optionally install + launch it.
# Usage: ./build-app.sh [run]
set -euo pipefail

TARGET=sim-arm64
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PREFIX="$ROOT/prefix/$TARGET"
BUILD="$HERE/build"
APP="$BUILD/DinoPoc.app"
MIN_IOS=16.0
TRIPLE="arm64-apple-ios${MIN_IOS}-simulator"
SDKPATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$PREFIX/lib/gio/modules/pkgconfig"
CFLAGS="$(pkg-config --cflags gio-2.0 gee-0.8 gdk-pixbuf-2.0)"
LIBS="$(pkg-config --libs --static libsoup-3.0 gee-0.8 gdk-pixbuf-2.0 gioopenssl libgcrypt libomemo-c libsrtp2)"

rm -rf "$APP" && mkdir -p "$APP"

xcrun -sdk iphonesimulator swiftc \
  -target "$TRIPLE" \
  -import-objc-header "$HERE/bridge.h" \
  $(printf -- '-Xcc %s ' $CFLAGS) -Xcc -I"$PREFIX/include" \
  "$HERE"/Sources/*.swift \
  -L "$PREFIX/lib" -L "$PREFIX/lib/gio/modules" -L "$PREFIX/lib/dino/plugins" \
  -ldinoios -ldino -lxmpp-vala -lqlite -lcrypto-vala \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/omemo.a" \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/http-files.a" \
  $LIBS \
  -o "$APP/DinoPoc"

cp "$HERE/Info.plist" "$APP/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "run" ]; then
  xcrun simctl boot "iPhone 17" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install booted "$APP"
  xcrun simctl launch booted im.dino.ios.poc
fi
