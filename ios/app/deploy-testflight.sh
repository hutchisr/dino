#!/usr/bin/env bash
# Build, App-Store-sign and upload Gecko to TestFlight (App Store Connect).
# Unlike ad-hoc, testers need no UDID, no Developer Mode, and get auto-updates.
#
# Usage: ASC_KEY_ID=XXXX ASC_ISSUER_ID=yyyy-... ./deploy-testflight.sh
#
# One-time prerequisites (you, in the web portals):
#   1. App Store Connect → My Apps → + → New App for bundle id
#      `me.anemoneya.gecko`. The *store name* must be globally unique, so use
#      something like "Gecko XMPP" (the on-device name stays "Gecko").
#   2. Agree to the Free Apps agreement (Business section) — TestFlight needs it.
#   3. App Store Connect → Users and Access → Integrations → App Store Connect
#      API → generate a key (App Manager role). Note the Key ID + Issuer ID and
#      save AuthKey_<KeyID>.p8 to ~/.appstoreconnect/private_keys/.
#   4. Developer portal → Profiles → an *App Store* distribution profile for EACH
#      app id (no devices), download + install:
#        - me.anemoneya.gecko                     (App Groups + Push)
#        - me.anemoneya.gecko.NotificationService (App Groups)
#
# Overridable via environment:
#   SIGN_IDENTITY  distribution identity (default: first "Apple Distribution")
#   PROFILE        app's App Store .mobileprovision
#   NSE_PROFILE    NSE's App Store .mobileprovision
#   BUNDLE_ID      app bundle id (default me.anemoneya.gecko)
#   BUILD_NUMBER   CFBundleVersion to stamp (default: current UTC timestamp)
#   ASC_KEY_ID     App Store Connect API key id   (required for upload)
#   ASC_ISSUER_ID  App Store Connect API issuer id (required for upload)
#   VALIDATE_ONLY  "1" to validate without uploading
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BUNDLE_ID="${BUNDLE_ID:-me.anemoneya.gecko}"
NSE_BUNDLE_ID="${BUNDLE_ID}.NotificationService"
APP_GROUP="group.me.anemoneya.gecko"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

# --- resolve a distribution signing identity ------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Distribution[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Apple Distribution' certificate in your keychain." >&2
  exit 1
fi

# --- find an App Store profile for a given app id -------------------------
# App Store = distribution (get-task-allow false) with NO provisioned devices
# (ad-hoc has devices; enterprise has ProvisionsAllDevices).
find_appstore_profile() {
  python3 - "$1" <<'EOF'
import glob, os, plistlib, subprocess, sys
want = sys.argv[1]
home = os.path.expanduser("~")
paths = glob.glob(f"{home}/Library/MobileDevice/Provisioning Profiles/*.mobileprovision") + \
        glob.glob(f"{home}/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")
best = None
for p in paths:
    raw = subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout
    try:
        pl = plistlib.loads(raw)
    except Exception:
        continue
    ents = pl.get("Entitlements", {})
    appid = ents.get("application-identifier", "")
    bid = appid.split(".", 1)[1] if "." in appid else ""
    if bid != want:
        continue
    if ents.get("get-task-allow", False) or pl.get("ProvisionedDevices") or pl.get("ProvisionsAllDevices"):
        continue   # not App Store
    has_groups = "com.apple.security.application-groups" in ents
    exp = pl.get("ExpirationDate")
    score = (has_groups, exp.timestamp() if exp else 0)
    if best is None or score > best[0]:
        best = (score, p)
if best:
    print(best[1])
EOF
}

PROFILE="${PROFILE:-$(find_appstore_profile "$BUNDLE_ID")}"
NSE_PROFILE="${NSE_PROFILE:-$(find_appstore_profile "$NSE_BUNDLE_ID")}"
for v in "PROFILE:$BUNDLE_ID:$PROFILE" "NSE_PROFILE:$NSE_BUNDLE_ID:$NSE_PROFILE"; do
  name="${v%%:*}"; rest="${v#*:}"; bid="${rest%%:*}"; path="${rest#*:}"
  if [ -z "$path" ]; then
    echo "error: no App Store profile for $bid." >&2
    echo "  Create an App Store distribution profile for App ID '$bid'," >&2
    echo "  download + install it, then re-run. (Or set $name=...)" >&2
    exit 1
  fi
done

TEAM_ID=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)
echo "identity:    $SIGN_IDENTITY"
echo "team:        $TEAM_ID"
echo "app profile: $PROFILE"
echo "nse profile: $NSE_PROFILE"
echo "build:       $BUILD_NUMBER"

# --- build ----------------------------------------------------------------
if [ -d "$ROOT/build-device-arm64" ]; then
  ninja -C "$ROOT/build-device-arm64" >/dev/null
  ninja -C "$ROOT/build-device-arm64" install >/dev/null
fi
"$HERE/build-app.sh" build device-arm64

# --- stage + re-sign (App Store distribution) -----------------------------
STAGE="$HERE/build-device-arm64/testflight"
APP="$STAGE/Gecko.app"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$HERE/build-device-arm64/Gecko.app" "$STAGE/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
# App Store requires a monotonically increasing build number, matched app+NSE.
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"

cat > "$STAGE/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>get-task-allow</key>
	<false/>
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP</string>
	</array>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM_ID.$BUNDLE_ID</string>
	</array>
</dict>
</plist>
EOF

APPEX="$APP/PlugIns/NotificationService.appex"
if [ -d "$APPEX" ]; then
  plutil -replace CFBundleIdentifier -string "$NSE_BUNDLE_ID" "$APPEX/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APPEX/Info.plist"
  cp "$NSE_PROFILE" "$APPEX/embedded.mobileprovision"
  cat > "$STAGE/nse-entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$NSE_BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>get-task-allow</key>
	<false/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP</string>
	</array>
</dict>
</plist>
EOF
  codesign -f -s "$SIGN_IDENTITY" --timestamp --entitlements "$STAGE/nse-entitlements.plist" "$APPEX"
fi
codesign -f -s "$SIGN_IDENTITY" --timestamp --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

# --- package IPA ----------------------------------------------------------
rm -rf "$STAGE/Payload" "$STAGE/Gecko.ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry Gecko.ipa Payload && rm -rf Payload)
echo "packaged: $STAGE/Gecko.ipa (build $BUILD_NUMBER)"

# --- validate / upload to App Store Connect -------------------------------
if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo
  echo "Built + signed for the App Store. To upload, set ASC_KEY_ID and"
  echo "ASC_ISSUER_ID (and put AuthKey_<KeyID>.p8 in ~/.appstoreconnect/private_keys/),"
  echo "then re-run — or upload $STAGE/Gecko.ipa via the Transporter app."
  exit 0
fi

action="--upload-app"
[ "${VALIDATE_ONLY:-}" = "1" ] && action="--validate-app"
echo "running altool $action ..."
xcrun altool $action --type ios --file "$STAGE/Gecko.ipa" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo
echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect →"
echo "TestFlight after ~5-30 min of processing. Then add testers and (for"
echo "external testers) submit the first build for the quick beta review."
