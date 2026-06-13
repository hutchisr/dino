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
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)"/\1/p' | head -1)}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no codesigning identity found" >&2
  exit 1
fi

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
    explicit = not appid.endswith("*")
    candidates.append(((has_push, explicit), p))
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
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM_ID.$BUNDLE_ID</string>
	</array>
</dict>
</plist>
EOF
codesign -f -s "$SIGN_IDENTITY" --timestamp=none --entitlements "$STAGE/entitlements.plist" "$APP"

# --- install + launch -----------------------------------------------------
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID"
echo "deployed $BUNDLE_ID to $DEVICE_NAME"
