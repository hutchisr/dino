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

# On the simulator, entitlements (aps-environment for APNs) live in a
# __TEXT,__entitlements section embedded at link time; putting them in the
# ad-hoc code signature makes AMFI refuse to spawn the binary.
SIM_ENTS=""
if [ "$TARGET" = "sim-arm64" ]; then
  cat > "$BUILD/sim-entitlements.plist" <<'EOF2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>998J34UYP5.me.anemoneya.gecko</string>
	<key>com.apple.developer.team-identifier</key>
	<string>998J34UYP5</string>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.me.anemoneya.gecko</string>
	</array>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF2
  SIM_ENTS="-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker $BUILD/sim-entitlements.plist"
fi

xcrun -sdk "$SDK" swiftc \
  -target "$TRIPLE" \
  -import-objc-header "$HERE/bridge.h" \
  $(printf -- '-Xcc %s ' $CFLAGS) -Xcc -I"$PREFIX/include" \
  $SIM_ENTS \
  "$HERE"/Sources/*.swift \
  "$HERE"/GeckoKit/Sources/GeckoKit/*.swift \
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

# ---- Notification Service Extension ----
# Decrypts/filters pushes on-device. An app-extension executable has no main()
# of its own; its entry point is _NSExtensionMain (from Foundation) and the
# principal class comes from the Info.plist. On the simulator its entitlements
# (App Group) ride in a __TEXT,__entitlements section just like the host app.
APPEX="$APP/PlugIns/NotificationService.appex"
mkdir -p "$APPEX"
NSE_ENTS=""
if [ "$TARGET" = "sim-arm64" ]; then
  cat > "$BUILD/nse-entitlements.plist" <<'EOF3'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>998J34UYP5.me.anemoneya.gecko.NotificationService</string>
	<key>com.apple.developer.team-identifier</key>
	<string>998J34UYP5</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.me.anemoneya.gecko</string>
	</array>
	<!-- Suppress muted-conversation banners. This is a managed entitlement that
	     Apple must grant before it works on a real device; the simulator does
	     not validate entitlements against a provisioning profile, so we can
	     exercise the suppression path here while the request is pending. -->
	<key>com.apple.developer.usernotifications.filtering</key>
	<true/>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF3
  NSE_ENTS="-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker $BUILD/nse-entitlements.plist"
fi

xcrun -sdk "$SDK" swiftc \
  -target "$TRIPLE" \
  -parse-as-library \
  -module-name NotificationService \
  -import-objc-header "$HERE/bridge.h" \
  $(printf -- '-Xcc %s ' $CFLAGS) -Xcc -I"$PREFIX/include" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  $NSE_ENTS \
  "$ROOT"/nse/*.swift \
  -L "$PREFIX/lib" -L "$PREFIX/lib/gio/modules" -L "$PREFIX/lib/dino/plugins" \
  -ldinoios -ldino -lxmpp-vala -lqlite -lcrypto-vala \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/omemo.a" \
  -Xlinker -force_load -Xlinker "$PREFIX/lib/dino/plugins/http-files.a" \
  $LIBS \
  -o "$APPEX/NotificationService"
cp "$ROOT/nse/Info.plist" "$APPEX/Info.plist"
codesign --force --sign - "$APPEX"
echo "built $APPEX"

# Seal the host bundle last so its signature covers the embedded extension.
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
