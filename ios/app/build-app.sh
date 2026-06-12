#!/usr/bin/env bash
# Build Dino.app (SwiftUI shell + full libdino core) for the iOS Simulator
# or a device, and optionally install + launch it in the Simulator.
# Usage: ./build-app.sh [run] [sim-arm64|device-arm64]
set -euo pipefail

ACTION="${1:-build}"
TARGET="${2:-sim-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PREFIX="$ROOT/prefix/$TARGET"
BUILD="$HERE/build-$TARGET"
APP="$BUILD/Gecko.app"
MIN_IOS=26.0
case "$TARGET" in
  sim-arm64)    SDK=iphonesimulator; TRIPLE="arm64-apple-ios${MIN_IOS}-simulator" ;;
  device-arm64) SDK=iphoneos;        TRIPLE="arm64-apple-ios${MIN_IOS}" ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac
SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$PREFIX/lib/gio/modules/pkgconfig"
CFLAGS="$(pkg-config --cflags gio-2.0 gee-0.8 gdk-pixbuf-2.0)"
LIBS="$(pkg-config --libs --static libsoup-3.0 gee-0.8 gdk-pixbuf-2.0 gioopenssl libgcrypt libomemo-c libsrtp2)"

rm -rf "$APP" && mkdir -p "$APP"

xcrun -sdk "$SDK" swiftc \
  -target "$TRIPLE" \
  -import-objc-header "$HERE/bridge.h" \
  $(printf -- '-Xcc %s ' $CFLAGS) -Xcc -I"$PREFIX/include" \
  "$HERE"/Sources/*.swift \
  -L "$PREFIX/lib" -L "$PREFIX/lib/gio/modules" -L "$PREFIX/lib/dino/plugins" \
  -ldinoios -ldino -lxmpp-vala -lqlite -lcrypto-vala \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/omemo.a" \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/http-files.a" \
  $LIBS \
  -o "$APP/Gecko"

cp "$HERE/Info.plist" "$APP/Info.plist"
# app icon sizes from the master image
if [ -f "$HERE/AppIcon.png" ]; then
  sips -z 120 120 "$HERE/AppIcon.png" --out "$APP/AppIcon60x60@2x.png" >/dev/null
  sips -z 180 180 "$HERE/AppIcon.png" --out "$APP/AppIcon60x60@3x.png" >/dev/null
  sips -z 152 152 "$HERE/AppIcon.png" --out "$APP/AppIcon76x76@2x~ipad.png" >/dev/null
fi
codesign --force --sign - "$APP"
echo "built $APP"

if [ "$TARGET" = "device-arm64" ]; then
  # package as an .ipa for (re-)signing and device installation
  rm -rf "$BUILD/Payload" "$BUILD/Gecko.ipa"
  mkdir -p "$BUILD/Payload"
  cp -R "$APP" "$BUILD/Payload/"
  (cd "$BUILD" && zip -qry Gecko.ipa Payload)
  echo "built $BUILD/Gecko.ipa"
fi

if [ "$ACTION" = "run" ] && [ "$TARGET" = "sim-arm64" ]; then
  xcrun simctl boot "iPhone 17" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install booted "$APP"
  xcrun simctl launch booted im.dino.ios.poc
fi
