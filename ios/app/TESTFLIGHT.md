# TestFlight

The clean way to get builds to testers: no UDIDs, no Developer Mode, automatic
updates. More upfront setup than ad-hoc, most of it one-time in App Store
Connect.

## One-time setup (web)

1. **App record** — App Store Connect → Apps → **+** → New App, bundle id
   `me.anemoneya.gecko`. The store *name* must be globally unique (e.g.
   "Gecko XMPP"); the on-device name stays "Gecko".
2. **Agreement** — Business → agree to the **Free Apps** agreement (TestFlight
   won't work until this is signed).
3. **API key for uploads** — Users and Access → Integrations → **App Store
   Connect API** → generate a key with the **App Manager** role. Note the
   **Key ID** + **Issuer ID**, download `AuthKey_<KeyID>.p8`, and move it to
   `~/.appstoreconnect/private_keys/`. (Keep the .p8 out of git.)
4. **App Store profiles** — Developer portal → Profiles → create an **App
   Store** distribution profile for each app id (no devices), download + install:
   - `me.anemoneya.gecko` (App Groups + Push)
   - `me.anemoneya.gecko.NotificationService` (App Groups)
   (You already have the Apple Distribution cert from the ad-hoc work.)

## Each release

```sh
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... ./app/deploy-testflight.sh
```

Builds, App-Store-signs (app + NSE), stamps a fresh build number, packages the
IPA, and uploads. Use `VALIDATE_ONLY=1` to dry-run, or omit the ASC_* vars to
just build the IPA and upload it later via the Transporter app.

## After upload

1. Wait ~5–30 min for processing (App Store Connect → TestFlight → Builds).
2. **Export compliance**: it'll ask about encryption. Gecko uses E2EE (OMEMO);
   answer per your situation (messaging E2EE typically "uses encryption" →
   "qualifies for exemption"). To stop the per-build prompt, add
   `ITSAppUsesNonExemptEncryption` to Info.plist once you've decided.
3. **Add testers**:
   - *Internal* (up to 100): App Store Connect users on your team — instant, no
     review.
   - *External* (up to 10,000): add by email; the **first** build needs a quick
     (~1 day) Beta App Review, then it's available.
4. Testers install the **TestFlight** app and accept the invite. Updates are
   automatic on each new upload.
