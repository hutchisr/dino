#!/usr/bin/env bash
# Build, re-sign and deploy Gecko to a physical iPhone, then launch it.
#
# Usage: ./deploy-phone.sh ["device name substring"]
#
# Overridable via environment:
#   SIGN_IDENTITY  codesigning identity (default: first valid one)
#   PROFILE        path to a .mobileprovision provisioning this device
#   BUNDLE_ID      bundle id to install under (must match the profile)
set -euo pipefail

DEVICE_NAME="${1:-iPhone 17 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="${BUNDLE_ID:-me.anemoneya.gecko}"

# --- resolve device -------------------------------------------------------
DEVICE_JSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null
read -r DEVICE_ID DEVICE_UDID < <(python3 - "$DEVICE_JSON" "$DEVICE_NAME" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
needle = sys.argv[2].lower()
for dev in data["result"]["devices"]:
    name = dev.get("deviceProperties", {}).get("name", "")
    if needle in name.lower():
        print(dev["identifier"], dev.get("hardwareProperties", {}).get("udid", ""))
        break
EOF
)
rm -f "$DEVICE_JSON"
if [ -z "${DEVICE_ID:-}" ]; then
  echo "error: no paired device matching '$DEVICE_NAME'" >&2
  exit 1
fi

# --- resolve identity and profile ----------------------------------------
# Development profiles must be signed with an "Apple Development" cert — an
# "Apple Distribution" cert here yields 0xe8008015 at install. Prefer the dev
# cert (it may not sort first) and only fall back to the first identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)"/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no codesigning identity found" >&2
  exit 1
fi
echo "identity: $SIGN_IDENTITY"

if [ -z "${PROFILE:-}" ]; then
  PROFILE=$(python3 - "$DEVICE_UDID" <<'EOF'
import glob, os, plistlib, subprocess, sys
udid = sys.argv[1]
home = os.path.expanduser("~")
paths = glob.glob(f"{home}/Library/MobileDevice/Provisioning Profiles/*.mobileprovision") + \
        glob.glob(f"{home}/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")
candidates = []
for p in paths:
    raw = subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout
    try:
        pl = plistlib.loads(raw)
    except Exception:
        continue
    if udid not in pl.get("ProvisionedDevices", []):
        continue
    ents = pl.get("Entitlements", {})
    appid = ents.get("application-identifier", "")
    has_push = "aps-environment" in ents
    has_groups = "com.apple.security.application-groups" in ents
    explicit = not appid.endswith("*")
    candidates.append(((has_groups, has_push, explicit), p))
if candidates:
    candidates.sort(reverse=True)
    print(candidates[0][1])
EOF
)
fi
if [ -z "$PROFILE" ]; then
  echo "error: no provisioning profile covers device $DEVICE_UDID" >&2
  exit 1
fi

TEAM_ID=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)
PROFILE_HAS_PUSH=$(security cms -D -i "$PROFILE" 2>/dev/null | grep -c 'aps-environment' || true)

# --- resolve the Notification Service Extension profile -------------------
# The .appex is its own bundle and needs a profile for its own app id, with
# the App Groups capability, covering this device.
NSE_BUNDLE_ID="${BUNDLE_ID}.NotificationService"
APP_GROUP="group.me.anemoneya.gecko"
if [ -z "${NSE_PROFILE:-}" ]; then
  NSE_PROFILE=$(python3 - "$DEVICE_UDID" "$NSE_BUNDLE_ID" <<'EOF'
import glob, os, plistlib, subprocess, sys
udid, want = sys.argv[1], sys.argv[2]
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
    if udid not in (pl.get("ProvisionedDevices") or []):
        continue
    ents = pl.get("Entitlements", {})
    appid = ents.get("application-identifier", "")
    bid = appid.split(".", 1)[1] if "." in appid else ""
    if bid != want:                       # explicit match for the extension id
        continue
    has_groups = "com.apple.security.application-groups" in ents
    if best is None or (has_groups and not best[0]):
        best = (has_groups, p)
if best:
    print(best[1])
EOF
)
fi
if [ -z "$NSE_PROFILE" ]; then
  echo "error: no provisioning profile for $TEAM_ID.$NSE_BUNDLE_ID covering this device." >&2
  echo "  Create an 'iOS App Development' profile in the developer portal for App ID" >&2
  echo "  '$NSE_BUNDLE_ID' (App Groups capability enabled, your iPhone selected)," >&2
  echo "  download it, double-click to install, then re-run this script." >&2
  echo "  (Override with NSE_PROFILE=/path/to.mobileprovision.)" >&2
  exit 1
fi

# --- build ----------------------------------------------------------------
ROOT="$(dirname "$HERE")"
if [ -d "$ROOT/build-device-arm64" ]; then
  ninja -C "$ROOT/build-device-arm64" >/dev/null
  ninja -C "$ROOT/build-device-arm64" install >/dev/null
fi
"$HERE/build-app.sh" build device-arm64

# --- re-sign --------------------------------------------------------------
STAGE="$HERE/build-device-arm64/signed"
APP="$STAGE/Gecko.app"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$HERE/build-device-arm64/Gecko.app" "$STAGE/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Info.plist"
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
	<true/>
$( [ "$PROFILE_HAS_PUSH" -gt 0 ] && printf '\t<key>aps-environment</key>\n\t<string>development</string>' )
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

# Sign the Notification Service Extension first (nested-first), with its own
# profile + entitlements, so the host app's signature below seals it.
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
	<true/>
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

# --- install + launch -----------------------------------------------------
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID"
echo "deployed $BUNDLE_ID to $DEVICE_NAME"
