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
  (ios/push-proxy): content-free "New message" banners wake the user;
  opening the app reconnects (fast resume path) and syncs via MAM.
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
`DINO_AUTOOMEMO=1` (enable encryption before sending), and
`DINO_LOG_XMPP=all` (stanza log on stderr, visible via
`simctl launch --console-pty`).

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
  message with its conversation, OMEMO-decrypted body, and effective notify
  setting; `NSEFetcher` drives it from Swift and enriches the alert.
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
  scheduling, so this path needs notification permission but no APNs or
  filtering entitlement. It intentionally does not notify after Gecko quits.
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
conversation previews/unread counts/read markers (XEP-0333), typing
notifications (XEP-0085), file transfers (HTTP upload via libsoup,
OMEMO-encrypted aesgcm files, inline image previews, full-screen viewer;
note: GIO mime sniffing is extension-based on iOS — no shared-mime-info),
MUC management (join/leave, participant list, per-sender avatars/nicks),
emoji reactions (XEP-0444), message corrections (XEP-0308), replies
(XEP-0461), delivery markers, account settings (avatar publishing,
display name, password change, OMEMO fingerprint), TLS via the iOS trust
store, fast reconnect on foreground, client identity "Gecko" (phone),
verified device deployment (`ios/app/deploy-phone.sh`), and **push
notifications**: XEP-0357 + the containerized proxy in ios/push-proxy,
hosted on k8s (namespace `gecko`), verified end to end through APNs.
