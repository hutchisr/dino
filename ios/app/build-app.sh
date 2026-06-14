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

# Build-metadata Info.plist keys that Xcode injects automatically but raw
# swiftc does not. The App Store rejects bundles without them (DTPlatformName,
# the arm64 device capability, etc.); harmless on the simulator / ad-hoc.
SDK_VER="$(xcrun --sdk "$SDK" --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk "$SDK" --show-sdk-build-version)"
XCODE_VER="$(xcodebuild -version | awk 'NR==1{print $2}')"
XCODE_BUILD="$(xcodebuild -version | awk 'NR==2{print $3}')"
MACHINE_BUILD="$(sw_vers -buildVersion)"
DT_XCODE="$(echo "$XCODE_VER" | awk -F. '{printf "%02d%d%d", $1, $2, ($3==""?0:$3)}')"
APP_SHORT_VER="$(plutil -extract CFBundleShortVersionString raw "$HERE/Info.plist")"
case "$SDK" in
  iphoneos)        PLATFORM_NAME="iPhoneOS" ;;
  iphonesimulator) PLATFORM_NAME="iPhoneSimulator" ;;
  *)               PLATFORM_NAME="iPhoneOS" ;;
esac

add_build_metadata() {  # $1 = path to an Info.plist inside a built bundle
  plutil -replace CFBundleSupportedPlatforms -json "[\"$PLATFORM_NAME\"]" "$1"
  plutil -replace DTPlatformName -string "$SDK" "$1"
  plutil -replace DTPlatformVersion -string "$SDK_VER" "$1"
  plutil -replace DTSDKName -string "${SDK}${SDK_VER}" "$1"
  plutil -replace DTSDKBuild -string "$SDK_BUILD" "$1"
  plutil -replace DTXcode -string "$DT_XCODE" "$1"
  plutil -replace DTXcodeBuild -string "$XCODE_BUILD" "$1"
  plutil -replace DTCompiler -string "com.apple.compilers.llvm.clang.1_0" "$1"
  plutil -replace BuildMachineOSBuild -string "$MACHINE_BUILD" "$1"
  plutil -replace UIRequiredDeviceCapabilities -json '["arm64"]' "$1"
}

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
add_build_metadata "$APP/Info.plist"
# App icon: compile an asset catalog (actool) so the bundle ships Assets.car +
# CFBundleIconName, which the App Store requires (loose PNGs aren't accepted). A
# single 1024px universal icon lets actool rasterize every size it needs.
if [ -f "$HERE/AppIcon.png" ]; then
  ICONSET="$BUILD/AppIcon.xcassets/AppIcon.appiconset"
  rm -rf "$BUILD/AppIcon.xcassets"; mkdir -p "$ICONSET"
  sips -s format png -z 1024 1024 "$HERE/AppIcon.png" --out "$ICONSET/icon-1024.png" >/dev/null
  cat > "$ICONSET/Contents.json" <<'EOF_ICON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF_ICON
  actool "$BUILD/AppIcon.xcassets" \
    --compile "$APP" \
    --app-icon AppIcon \
    --platform "$SDK" \
    --minimum-deployment-target "$MIN_IOS" \
    --target-device iphone \
    --output-partial-info-plist "$BUILD/icon-partial.plist" \
    --output-format human-readable-text >/dev/null
  /usr/libexec/PlistBuddy -c "Merge $BUILD/icon-partial.plist" "$APP/Info.plist"
  # actool only nests CFBundleIconName under CFBundleIcons; the App Store also
  # wants it as a top-level key.
  plutil -replace CFBundleIconName -string AppIcon "$APP/Info.plist"
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
add_build_metadata "$APPEX/Info.plist"
# The extension's marketing version must match the host app's, or the App Store
# rejects the upload.
plutil -replace CFBundleShortVersionString -string "$APP_SHORT_VER" "$APPEX/Info.plist"
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
