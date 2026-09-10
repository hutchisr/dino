# Dino on Apple platforms

This directory contains a working port of Dino's core to iOS and Apple Silicon
Macs through Mac Catalyst. GTK4 does not run on either platform, so the approach
is:

* Cross-compile the non-UI core — `qlite`, `xmpp-vala`, `libdino`,
  `crypto-vala`, and the omemo + http-files plugins — and their GLib stack as
  **static libraries** for each Apple ABI.
* Boot the full libdino service stack through a small bridge library
  (`ios/bridge`) that exposes a JSON-over-callback C API.
* Put a native **SwiftUI** front end on top (`ios/app`), using Mac Catalyst for
  the desktop build.

## Status: what works today

Verified end-to-end in the iOS Simulator (arm64) against real servers
(xmpp.is, conversations.im) on 2026-06-12:

* Full libdino service stack: database (sqlite in the app sandbox),
  StreamInteractor and all managers, message/conversation persistence
  across app restarts.
* Login with SCRAM over STARTTLS (glib-networking OpenSSL backend,
  certificate verification against a bundled CA file).
* Roster and bookmark sync (MUC conversations appear after login).
* One-to-one messaging, both directions.
* **OMEMO**: own device bundle published, peer bundles fetched, messages
  sent encrypted (verified at the stanza level) and incoming encrypted
  messages decrypted — via statically linked libomemo-c/libgcrypt and the
  omemo plugin built without its GTK UI.
* HTTP file upload plugin compiles and registers (libsoup3); no file-picker
  UI is wired up in the Swift shell yet.

The Apple Silicon Mac Catalyst dependency/core build, Xcode build, application
launch, window creation, and hide/restore lifecycle were verified on 2026-08-24.
It uses the same libdino, OMEMO, HTTP-file, and SwiftUI implementations as iOS;
live-account interoperability was not independently re-run during that build.

Known gaps / not done:

* Push notifications work via XEP-0357 + the bundled proxy
  (ios/push-proxy): content-free "New message" banners wake the user, carry an
  initial unread badge from the server summary, and the NSE corrects the badge
  from libdino's authoritative unread state after syncing. Opening the app
  reconnects (fast resume path) and syncs via MAM.
  Notable pitfalls encoded in the implementation: the publish arrives as
  an iq-set (not a pubsub message event), and the push service must be a
  full jid with a fixed resource — iq-sets to a bare account jid are
  answered by the server itself and never reach a client bot. On the
  simulator, entitlements must live in a __TEXT,__entitlements section
  (link-time), not the ad-hoc signature.
* Calls (`plugin-rtp`/`plugin-ice`): not ported. GStreamer publishes
  official iOS binaries, so this is feasible but is its own project.
* JID stringprep uses a casefold fallback (`-Dicu=disabled`); full
  ICU-based stringprep/IDNA would require cross-compiling ICU.
* OpenPGP plugin: not ported (GPGME on iOS is impractical).

## Layout

| Path | Purpose |
| --- | --- |
| `build-deps.sh` | Cross-compiles the dependency stack into `prefix/<target>`: GLib (+libffi, pcre2, proxy-libintl), libgee, gdk-pixbuf (+libpng), OpenSSL, glib-networking, libgpg-error, libgcrypt, protobuf-c, libomemo-c, libsrtp2, libpsl, libsoup3 (+nghttp2). Generates the Meson cross file. |
| `build-core.sh` | Builds Dino (core + crypto-vala + omemo + http-files plugins + the bridge) against that prefix: `-Dui=disabled -Dicu=disabled -Dios-bridge=enabled -Dplugin-omemo=enabled -Dplugin-http-files=enabled`. |
| `bridge/` | `dino_ios.vala`: boots a non-GTK `Dino.Application`, registers the statically linked plugins, and exposes a C API (`dinoios.h`) — events flow to Swift as JSON lines on a single callback. `tls_glue.c` statically registers the OpenSSL GIO TLS backend. |
| `app/` | Shared SwiftUI app for iOS and Mac Catalyst. `../Gecko.xcodeproj` manages the app + notification service extension against `ios/prefix/<target>`; `build-app.sh` uses direct `swiftc` builds on iOS and the Xcode Catalyst driver on macOS. |
| `compat/ios-compat.h` | Declares symbols (`pipe2`, `dup3`, `getentropy`) that recent iOS SDKs export from libSystem but hide in headers, which otherwise breaks autoconf/Meson feature detection. |

## Reproduce

For the iOS Simulator:

```sh
ios/build-deps.sh sim-arm64
ios/build-core.sh sim-arm64
ios/app/build-app.sh run sim-arm64
```

For an Apple Silicon Mac:

```sh
ios/build-deps.sh catalyst-arm64
ios/build-core.sh catalyst-arm64
ios/app/build-app.sh run catalyst-arm64
```

Or open `Gecko.xcodeproj` in Xcode and build the shared `Gecko` scheme. The
scheme selects `ios/prefix/sim-arm64`, `ios/prefix/device-arm64`, or
`ios/prefix/catalyst-arm64` from the destination SDK.

Both app targets require OS 26 and use the system's Liquid Glass toolbar and
sheet treatments. Keep toolbar actions as native `ToolbarItem` /
`ToolbarItemGroup` controls rather than fixed-size stacks with custom hover
backgrounds or stacked glass treatments. Chat's trailing actions use the
labeled `ToolbarItemGroup` initializer, which wraps them in a native
`ControlGroup` so they share one glass background on Catalyst as well as iOS.
The label describes the group if it collapses into a menu when space is tight.
The custom chat composer groups its
field, controls, and accessory banners in one `GlassEffectContainer`; its
6-point spacing is the glass merging threshold, not the layout gap. Message
bubbles and attachment thumbnails remain content surfaces, not glass.
Catalyst retains its native Contacts search field, Escape shortcuts, and media
window close controls; the media viewer keeps its immersive black backdrop.
A fixed `ToolbarSpacer` separates Contacts' Add action from its search field
into distinct glass backgrounds.
Catalyst's standalone sheet Close and Add buttons use `.buttonStyle(.glass)`
with the toolbar's shared background hidden, so the visible circle is the
interactive control rather than a larger decorative toolbar background.
Four-point label padding restores the roughly 36-point toolbar height.

Mac Catalyst uses a persistent desktop lifecycle: it keeps XMPP connected when
the window is hidden, enables GLib network monitoring and XEP-0198 resumption,
and identifies as a desktop client. iOS retains its delayed clean disconnect
before suspension, disabled network monitor, and non-resumable stream policy.
The Mac close button orders the underlying window out instead of destroying its
`UIWindowScene`, so the process and XMPP connection remain alive; Dock
activation orders that same window back in front. Catalyst exposes no public
UIKit close-veto callback, so this local build forwards the underlying AppKit
window/application delegates through runtime proxies. Revisit that unsupported
interop before a Mac App Store submission.

The app supports headless automation for testing via environment variables
(set through `SIMCTL_CHILD_*`): `DINO_AUTOLOGIN=jid:password`,
`DINO_AUTOPEER=jid` (opens a chat), `DINO_AUTOSEND=text`,
`DINO_AUTOSENDFILE=1` (generated PNG) or `DINO_AUTOSENDFILE=svg`,
`DINO_AUTOOMEMO=1` (enable encryption before sending), and
`DINO_LOG_XMPP=all` (stanza log on stderr, visible via
`simctl launch --console-pty`).

Chat UI regressions run without an account using the in-memory fixtures in
`Model.swift`:

```sh
xcodebuild test -project Gecko.xcodeproj -scheme Gecko \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GeckoUITests/ChatVisibilityUITests
```

`testRoomDetailsSeparatesOnlineAndOfflineMembers` uses
`DINO_UI_TEST_ROOM_MEMBERS=1` with that fixture to open a group chat's Room
Details sheet and verify distinct online-participant and offline-member sections.

`LoginUITests` uses `DINO_UI_TEST_FIXTURE=login` to bypass core startup without
loading or changing stored accounts. Run it with
`-only-testing:GeckoUITests/LoginUITests` on either destination. It covers the
width-limited, safe-area-centered login panel, address-to-password Return-key
focus, credential-dependent button availability, and large-text scrolling on
iOS. The tests do not submit credentials or exercise server authentication.

Composer tests establish a post-keyboard baseline, then check each inserted
character and backspace across soft wraps and explicit line breaks. The image
test measures the actual preview button, not an inherited row identifier.
XCTest still waits for idle around input, so inspect recorded frames when
checking transient jumps that could disappear before an assertion runs.

Audio attachment regressions use `DINO_UI_TEST_AUDIO=1` with the
`chat-visibility` fixture: locally generated PCM audio plus a corrupt file,
without an account or network access. The audio cases in
`ChatVisibilityUITests` exercise switching, seeking to the end, replay, and
failure UI with sharing preserved on both iOS and Catalyst. Save-button coverage
checks the native Files picker and cancellation on iOS, and exports the audio
under its original filename with intact PCM samples on Catalyst.
Sharing coverage checks the popover's distance from two tapped audio buttons on
Catalyst and completing/reopening the share sheet on iOS. Save and share use
matching plain SwiftUI buttons with adjoining 44-point tap targets. An invisible
UIKit view behind share supplies the popover anchor, avoiding both Catalyst's
native button bezel and `ShareLink`'s inferred geometry inside a scrolling chat.
The Catalyst attachment context menu also offers Share alongside Save As for
completed local files of any type. It reuses the same UIKit presenter with an
anchor behind the attachment content, not the row or app window. The image
context-menu regression checks popover proximity and dismissal/reopening.

The custom reaction picker keeps its SwiftUI sheet, quick reactions, and search.
On Catalyst its full catalog uses fixed-size, reusable `UICollectionView` cells
instead of SwiftUI grid buttons; iOS retains the original lazy grid. Filtering
is evaluated once per body, and unrelated updates do not reload native cells.
`testCustomReactionPickerSearchToggleAndCancelPreserveDraft` checks searching,
adding/removing a reaction, reopening, clearing search, and cancellation. The
DEBUG fixture updates reactions locally with a message revision bump; it does
not call the unstarted XMPP core or verify server delivery.

Run the complete Catalyst UI suite (including the shared media/scroll tests and
`CatalystInteractionUITests`) on an unlocked Mac desktop:

```sh
xcodebuild test -project Gecko.xcodeproj -scheme Gecko \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath /tmp/GeckoCatalystUITests \
  -resultBundlePath /tmp/GeckoCatalystUITests.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=998J34UYP5 \
  ENABLE_HARDENED_RUNTIME=NO
```

Choose unused output paths for a fresh run. A local Apple Development identity
and team are required; the team override restores the value cleared by the
normal ad-hoc Catalyst app configuration. The identity/hardened-runtime
overrides avoid the test runner being killed before bootstrapping on the current
host. These are test-command overrides, not release signing settings. Keep UI
runners serial: the keyboard, Dock, clipboard, and native dialogs are shared.

The desktop-only interaction tests reuse the account-free `chat-visibility`
fixture. They cover main-window close/Dock reopen and app hide/activation with
draft preservation, composer autofocus and Return versus Shift-Return,
Command-N Contacts and cancellation, Command-comma Settings and Escape,
text Copy/Reply cancellation, and repeated secondary-media-window closure.
Composer submission checks local draft/focus behavior, not XMPP delivery.
Native window counts use direct application children because Catalyst also
exposes nested UIKit accessibility windows. Reopening the closed main window
uses the newly launched test app's Dock icon; `XCUIApplication.activate()` alone
does not deliver the native reopen event.

Catalyst Contacts uses a native `UISearchTextField` so clearing updates both the
visible editor and the search binding. Its regression in `ChatVisibilityUITests`
checks two clear cycles with screenshot OCR of the restored placeholder, then
checks that subsequent typing starts empty; an empty accessibility value alone
can miss stale rendered text. The GIF/WebP tests likewise inspect actual pixels:
screenshots are sampled directly within a deadline instead of a predicate
waiter. This removes the waiter that interrupted an in-flight accessibility
snapshot during verification; screenshot/decode errors still fail the test.

The chat's composer clearance lives in the non-lazy bottom anchor, not a bottom
content margin. Together with `.defaultScrollAnchor(..., for: .sizeChanges)`,
this keeps multiline growth/deletion bottom-aligned during layout. Changing
content margins and correcting afterward can briefly restore an estimated
older row before snapping back. Disable resize anchoring while the user is
scrolling or reading older messages; keep initial positioning explicit.

Row visibility and history anchors are measured from passive UIKit row
backgrounds during coalesced post-layout scroll work. Keep per-row SwiftUI
`onGeometryChange`/scroll-visibility observers out of the lazy stack: Catalyst
can loop in AttributeGraph row placement and coordinate-space resolution before
observer actions run, so deferring those actions alone does not prevent a hang.
The native probes are weakly registered and do not publish geometry into
SwiftUI state during layout.

## Changes to the main tree

All desktop-neutral (defaults unchanged; GTK Dino still builds):

* `meson_options.txt` / `meson.build`: new `ui`, `icu`, and `ios-bridge`
  feature options; `libqrencode` only required when the UI is built.
* `xmpp-vala/src/module/jid.vala`: casefold JID-prep fallback under
  `-Dicu=disabled` (`NO_ICU` define).
* `plugins/omemo`: UI sources, GTK/libadwaita/qrencode deps and gresources
  are skipped when the UI is disabled (`DINO_NO_UI` guards the few UI
  registrations in `plugin.vala`); `shared_library` → `library` so
  `--default-library static` applies; `register_plugin.vala` (the GModule
  entry point) excluded from static builds to avoid duplicate symbols.
* `plugins/http-files`: same treatment; dropped an unused `using Gtk`.
* `libdino/src/application.vala`: don't overwrite
  `connection_manager.log_options` when `--print-xmpp` wasn't given.

## Design notes / gotchas

* **Static everything.** iOS forbids dlopen of unsigned dylibs, so all
  libraries are static and plugins are registered by direct instantiation
  in the bridge instead of Dino's GModule loader.
* **TLS backend registration**: `g_io_openssl_load(NULL)` — GLib ≥ 2.56
  treats a NULL GTypeModule as static type registration. Must happen
  before the first `GTlsBackend` lookup (the bridge does it in
  `dino_ios_init_glib_tls`).
* **Threading**: a dedicated thread runs `GApplication.run()`; every
  bridge call marshals onto the GLib main context via `Idle.add`; events
  are emitted on the GLib thread and hopped to the main queue in Swift.
* **sqlite** comes from the iOS SDK (`libsqlite3.tbd`); the build drops a
  hand-written `sqlite3.pc` into the prefix.
* **pcre2 JIT** disabled (no executable pages on iOS).
* Vala cross-compiles cleanly: host `valac` emits C, Meson compiles it
  with the iOS clang. Watch for vala `char` being signed when doing
  byte-level work (see `esc()` in the bridge).
* **Image upload memory**: `ImageFileMetadataProvider` reads dimensions before
  decoding and omits the optional tiny thumbnail above 16,777,216 pixels
  (64 MiB of RGBA pixels). The original file and its dimensions still upload;
  no image resizing is applied. GdkPixbuf's PNG loader allocates the original
  raster even when asked for a scaled image, so scaling alone is not a bound.
  Metadata and hashing errors propagate to the send callback rather than
  abandoning its async task. Swift staging drains autoreleased `FileHandle`
  buffers per chunk; otherwise a chunked copy still retains a file's worth of
  memory. After `build-core.sh catalyst-arm64`, run
  `ios/build-catalyst-arm64/libdino/libdino-test -p /FileMetadata` for valid,
  oversized, corrupt-image, and unreadable-hash regression coverage.

## Notification Service Extension (in progress)

Per-conversation notification settings (off / mentions-only) cannot be
enforced server-side: Gecko is general-purpose, and public servers strip
sender+body from XEP-0357 push summaries for privacy (xmpp.is sends only a
count; Prosody defaults sender off too), so the proxy never learns which
conversation a push belongs to. The fix is on-device filtering in an NSE —
works on any server and also unlocks decrypted previews.

* **Phase 0 (done):** on iOS, GLib storage (dino.db / omemo.db) lives in
  the `group.me.anemoneya.gecko` App Group container so the NSE can read it.
  The local Catalyst build instead uses its per-user Library/Caches roots:
  local notifications need no NSE sharing, and avoiding an unentitled App Group
  lookup prevents macOS from asking for cross-app data access on every launch.
* **Phase 1 (done):** `ios/nse` builds `PlugIns/NotificationService.appex`
  (own `_NSExtensionMain` executable, App Group entitlement, sealed in the
  host bundle by build-app.sh). Verified the NSE spawns for a
  mutable-content push and reads the shared dino.db. `NSEStore` is the
  read-only accessor.
* **Phase 2 (done, validated on simulator):** `dino_ios_nse_fetch` boots a
  trimmed libdino in the extension (shared `boot_core`), points storage at
  the App Group container, connects, MAM-syncs, and returns each incoming
  message with its conversation, OMEMO-decrypted body, effective notify
  setting, and the aggregate unread count; `NSEFetcher` drives it from Swift,
  enriches the alert, and updates the app icon badge.
  Verified end to end: an OMEMO message to the offline account was
  connected, synced, decrypted on-device, and flagged for its muted
  conversation. Still to confirm on a real device, where the 24MB/30s
  budget is enforced (sim doesn't); a transient first-connect stream error
  auto-retries and eats into that budget — watch it on device.
* **Phase 3 (todo, gated):** suppress muted-conversation banners. Requires
  the `com.apple.developer.usernotifications.filtering` entitlement (Apple
  request on the dev account); enrichment in Phase 2 works without it.
* **Mac Catalyst local filtering (done):** the persistent Mac process posts
  local notifications for new live incoming items only while Gecko is not
  active. It suppresses muted conversations and non-mention MUC messages before
  scheduling and updates the Dock icon badge from the aggregate libdino unread
  count, so this path needs notification permission but no APNs or filtering
  entitlement. It intentionally does not notify after Gecko quits.
  Remote NSE suppression on macOS still requires Apple's same
  [`com.apple.developer.usernotifications.filtering`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering)
  managed entitlement plus an APS-signed Catalyst profile.

## Next steps

1. NSE Phase 2/3 (above); dedupe the occasional duplicate publish.
2. Calls (plugin-rtp/ice via GStreamer's official iOS binaries).
3. CI for the cross-compile.
4. **(TBD) XEP-0198 resumption across launches.** We currently disable SM
   resumption on iOS (`request_resumption = false` in `boot_core`) because the
   app/NSE process dies on backgrounding, losing the in-memory SM state — so
   `resume=true` only manufactured hibernated "ghost" sessions that fired
   phantom pushes forever. The optimization we gave up: skipping a re-login +
   MAM re-sync on every reconnect. To get it back the right way (Monal-style),
   persist the SM session state — `session_id` (previd), `h_inbound`/`h_outbound`,
   and the unacked outbound queue from `0198_stream_management.vala` — to the
   shared App Group, send `<resume previd h>` on launch (fall back to fresh bind
   on `<failed/>`), and add a process lock (Monal uses `flock`) so the app and
   the NSE never try to own/resume the same stream at once. Only worth it if MAM
   re-sync proves slow or battery-costly. See memory `gecko-push-filtering`.

Done beyond the basics: contact management (roster, presence,
subscription requests), sign in/out with stable OMEMO identity, avatars,
conversation previews/unread counts and app icon badges/read markers
(XEP-0333), typing notifications (XEP-0085), file transfers (HTTP upload via
OMEMO-encrypted aesgcm files, photo-library uploads that preserve animated GIF
and WebP files, memory-bounded inline GIF/WebP playback controlled by
tap-to-play/tap-to-pause format badges, and SVG previews/viewers rasterized in
a bounded, script-disabled, nonpersistent WebKit image document. SVGs with XML
document type or entity declarations are rejected. Static images still open
full-screen; note: GIO MIME sniffing is extension-based on iOS — no
shared-mime-info),
MUC management (join/leave, mediated and direct invitations, participant list,
per-sender avatars/nicks),
emoji reactions (XEP-0444), message corrections (XEP-0308), replies
(XEP-0461), delivery markers, account settings (avatar publishing,
display name, password change, OMEMO fingerprint), TLS via the iOS trust
store, fast reconnect on foreground, client identity "Gecko" (phone),
verified device deployment (`ios/app/deploy-phone.sh`), and **push
notifications**: XEP-0357 + the containerized proxy in ios/push-proxy,
hosted on k8s (namespace `gecko`), verified end to end through APNs.
