#!/usr/bin/env bash
# Build, ad-hoc-sign and package Gecko as an IPA + over-the-air install manifest
# for a remote tester's device (one whose UDID you registered and included in an
# Ad Hoc provisioning profile). Unlike deploy-phone.sh this never touches a
# connected device — it produces files you host over HTTPS and share a link to.
#
# Usage: ./deploy-friend.sh [tester-UDID]
#   Pass the tester's UDID to require profiles that cover it (recommended).
#
# Prerequisites (Apple Developer portal, one-time per tester):
#   1. Devices → register the tester's UDID.
#   2. Certificates → an "Apple Distribution" certificate (in your keychain).
#   3. Profiles → an *Ad Hoc* profile for EACH app id, with the tester's device:
#        - me.anemoneya.gecko                    (App Groups + Push)
#        - me.anemoneya.gecko.NotificationService (App Groups)
#      Download both and double-click to install them.
#
# Overridable via environment:
#   SIGN_IDENTITY   distribution identity (default: first "Apple Distribution")
#   PROFILE         path to the app's Ad Hoc .mobileprovision
#   NSE_PROFILE     path to the NSE's Ad Hoc .mobileprovision
#   BUNDLE_ID       app bundle id (default me.anemoneya.gecko)
#   DIST_BASE_URL   HTTPS base where you'll host the IPA + manifest
#                   (default https://dist.anemoneya.me)
set -euo pipefail

TESTER_UDID="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BUNDLE_ID="${BUNDLE_ID:-me.anemoneya.gecko}"
NSE_BUNDLE_ID="${BUNDLE_ID}.NotificationService"
APP_GROUP="group.me.anemoneya.gecko"
DIST_BASE_URL="${DIST_BASE_URL:-https://dist.anemoneya.me}"
DIST_BASE_URL="${DIST_BASE_URL%/}"

# --- resolve a distribution signing identity ------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Distribution[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Apple Distribution' certificate in your keychain." >&2
  echo "  Create one in the developer portal (Certificates → Apple Distribution)," >&2
  echo "  download + install it, or set SIGN_IDENTITY=..." >&2
  exit 1
fi

# --- find an Ad Hoc profile for a given app id ----------------------------
# Ad Hoc = distribution profile (get-task-allow false) that lists specific
# devices (non-empty ProvisionedDevices), unlike App Store (no devices) and
# Development (get-task-allow true).
find_adhoc_profile() {
  local want_bid="$1"
  python3 - "$want_bid" "$TESTER_UDID" <<'EOF'
import glob, os, plistlib, subprocess, sys
want, udid = sys.argv[1], sys.argv[2]
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
    devices = pl.get("ProvisionedDevices") or []
    if not devices or ents.get("get-task-allow", False):   # need Ad Hoc, not App Store/Development
        continue
    if udid and udid not in devices:
        continue
    has_groups = "com.apple.security.application-groups" in ents
    # prefer a profile that also has App Groups and the freshest expiry
    score = (has_groups, pl.get("ExpirationDate"))
    if best is None or score > best[0]:
        best = (score, p)
if best:
    print(best[1])
EOF
}

PROFILE="${PROFILE:-$(find_adhoc_profile "$BUNDLE_ID")}"
if [ -z "$PROFILE" ]; then
  echo "error: no Ad Hoc profile for $BUNDLE_ID${TESTER_UDID:+ covering $TESTER_UDID}." >&2
  echo "  Create an Ad Hoc profile for App ID '$BUNDLE_ID' including the tester's" >&2
  echo "  device, download + install it, then re-run. (Or set PROFILE=...)" >&2
  exit 1
fi
NSE_PROFILE="${NSE_PROFILE:-$(find_adhoc_profile "$NSE_BUNDLE_ID")}"
if [ -z "$NSE_PROFILE" ]; then
  echo "error: no Ad Hoc profile for $NSE_BUNDLE_ID${TESTER_UDID:+ covering $TESTER_UDID}." >&2
  echo "  Create an Ad Hoc profile for App ID '$NSE_BUNDLE_ID' including the" >&2
  echo "  tester's device, download + install it, then re-run. (Or set NSE_PROFILE=...)" >&2
  exit 1
fi

TEAM_ID=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)
PROFILE_HAS_PUSH=$(security cms -D -i "$PROFILE" 2>/dev/null | grep -c 'aps-environment' || true)

echo "identity:    $SIGN_IDENTITY"
echo "team:        $TEAM_ID"
echo "app profile: $PROFILE"
echo "nse profile: $NSE_PROFILE"

# --- build ----------------------------------------------------------------
if [ -d "$ROOT/build-device-arm64" ]; then
  ninja -C "$ROOT/build-device-arm64" >/dev/null
  ninja -C "$ROOT/build-device-arm64" install >/dev/null
fi
"$HERE/build-app.sh" build device-arm64

# --- re-sign (ad-hoc / distribution) --------------------------------------
STAGE="$HERE/build-device-arm64/adhoc"
APP="$STAGE/Gecko.app"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$HERE/build-device-arm64/Gecko.app" "$STAGE/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# Distribution entitlements: get-task-allow FALSE, and (ad-hoc) production APNs.
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
$( [ "$PROFILE_HAS_PUSH" -gt 0 ] && printf '\t<key>aps-environment</key>\n\t<string>production</string>' )
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

# NSE first (nested-first), then the host app seals it.
APPEX="$APP/PlugIns/NotificationService.appex"
if [ -d "$APPEX" ]; then
  plutil -replace CFBundleIdentifier -string "$NSE_BUNDLE_ID" "$APPEX/Info.plist"
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
  codesign -f -s "$SIGN_IDENTITY" --timestamp=none --entitlements "$STAGE/nse-entitlements.plist" "$APPEX"
fi
codesign -f -s "$SIGN_IDENTITY" --timestamp=none --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

# --- package IPA + OTA manifest -------------------------------------------
DIST="$HERE/build-device-arm64/dist"
rm -rf "$DIST" && mkdir -p "$DIST/Payload"
cp -R "$APP" "$DIST/Payload/"
(cd "$DIST" && zip -qry Gecko.ipa Payload && rm -rf Payload)

SHORT_VER=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist" 2>/dev/null || echo "1.0")
BUILD_VER=$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist" 2>/dev/null || echo "1")

cat > "$DIST/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key><string>software-package</string>
					<key>url</key><string>$DIST_BASE_URL/Gecko.ipa</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key><string>$BUNDLE_ID</string>
				<key>bundle-version</key><string>$SHORT_VER</string>
				<key>kind</key><string>software</string>
				<key>title</key><string>Gecko</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

INSTALL_URL="itms-services://?action=download-manifest&url=$DIST_BASE_URL/manifest.plist"
cat > "$DIST/index.html" <<EOF
<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Install Gecko</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1.3rem;line-height:1.55}
a.btn{display:inline-block;background:#16a34a;color:#fff;padding:.85rem 1.5rem;border-radius:13px;text-decoration:none;font-weight:600;margin:1rem 0}
.muted{color:#8e8e93;font-size:.9rem}</style></head><body>
<h2>Install Gecko (v$SHORT_VER)</h2>
<p>Open this page in <b>Safari</b> on your registered iPhone and tap below. iOS
will ask to install — confirm, then trust the developer under
Settings → General → VPN &amp; Device Management on first launch.</p>
<p><a class=btn href="$INSTALL_URL">Install Gecko</a></p>
<p class=muted>Build $SHORT_VER ($BUILD_VER).</p>
</body></html>
EOF

echo
echo "built ad-hoc distribution in: $DIST"
echo "  Gecko.ipa, manifest.plist, index.html"

# --- optional: publish to the gecko-dist static host ----------------------
if [ "${PUBLISH:-}" = "1" ]; then
  echo
  echo "publishing to gecko-dist (k8s)..."
  DISTHOST="$ROOT/dist-host"
  rm -rf "$DISTHOST/dist" && cp -R "$DIST" "$DISTHOST/dist"
  docker build --platform linux/amd64 -t lax.vultrcr.com/mercury/gecko-dist:latest "$DISTHOST"
  docker push lax.vultrcr.com/mercury/gecko-dist:latest
  kubectl apply -f "$DISTHOST/k8s.yaml"
  kubectl -n gecko rollout restart deploy/gecko-dist
  kubectl -n gecko rollout status deploy/gecko-dist --timeout=120s
  echo "published."
else
  echo
  echo "Next: host those three files at $DIST_BASE_URL over HTTPS (trusted cert"
  echo "required) — or re-run with PUBLISH=1 to push them to the gecko-dist host."
fi
echo
echo "Send the tester this page:  $DIST_BASE_URL/"
echo "Direct install link:        $INSTALL_URL"
echo
echo "NOTE: ad-hoc builds use PRODUCTION APNs. The push proxy currently runs in"
echo "sandbox mode (APNS_SANDBOX=1), so push won't reach this build until the"
echo "proxy also serves production. Messaging/everything else works regardless."
