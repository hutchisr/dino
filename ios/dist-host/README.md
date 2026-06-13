# Ad-hoc distribution to a tester

Get a signed Gecko build onto a remote tester's device (no cable), via an ad-hoc
IPA + over-the-air install link.

## One-time portal setup (per tester)

1. Get the tester's UDID — see [../udid-enroll](../udid-enroll) (they open a
   link, you read it from the logs / the page shows it).
2. Apple Developer portal:
   - **Devices** → register that UDID.
   - **Certificates** → create an **Apple Distribution** certificate (download +
     install into your keychain). `deploy-friend.sh` needs this — you currently
     have none.
   - **Profiles** → create an **Ad Hoc** profile for *each* app id, with the
     tester's device selected:
     - `me.anemoneya.gecko` (App Groups + Push capabilities)
     - `me.anemoneya.gecko.NotificationService` (App Groups)
     Download both and double-click to install.
3. One-time infra: point DNS for `dist.anemoneya.me` at the nginx ingress (same
   target as the other `*.anemoneya.me` records).

## Build + publish

```sh
PUBLISH=1 ./app/deploy-friend.sh <tester-UDID>
```

This builds the device app, ad-hoc-signs it (distribution cert + ad-hoc
profiles, `get-task-allow=false`, production APNs), packages `Gecko.ipa`,
generates the OTA `manifest.plist` + `index.html`, then bakes them into the
`gecko-dist` nginx image and rolls it out.

Without `PUBLISH=1` it just produces the artifacts in
`app/build-device-arm64/dist/` for you to host yourself.

## Share

Send the tester `https://dist.anemoneya.me/`. They open it in **Safari**, tap
Install, and on first launch trust the developer under **Settings → General →
VPN & Device Management**.

## Caveat: push

Ad-hoc builds use **production** APNs. The push proxy
([../push-proxy](../push-proxy)) runs in sandbox mode (`APNS_SANDBOX=1`), so push
won't reach an ad-hoc build until the proxy also serves production (e.g. retry
the production endpoint on `BadDeviceToken`). Everything else works.
