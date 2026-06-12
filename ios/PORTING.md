# Dino on iOS

This directory contains a working port of Dino's core to iOS. GTK4 does not
run on iOS, so the approach is:

* Cross-compile the non-UI core — `qlite`, `xmpp-vala`, `libdino`,
  `crypto-vala`, and the omemo + http-files plugins — and their GLib stack
  as **static libraries** for iOS.
* Boot the full libdino service stack through a small bridge library
  (`ios/bridge`) that exposes a JSON-over-callback C API.
* Put a native **SwiftUI** front end on top (`ios/app`).

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

Known gaps / not done:

* Push notifications (deliberately skipped for now): iOS suspends the app
  in the background and the TCP stream dies. Needs XEP-0357 + a push proxy
  + a Notification Service Extension. Until then, messages only arrive
  while the app is foregrounded (history catches up via MAM on reconnect).
* Calls (`plugin-rtp`/`plugin-ice`): not ported. GStreamer publishes
  official iOS binaries, so this is feasible but is its own project.
* TLS trust uses a CA bundle copied from the build host instead of the iOS
  trust store (would need a Security.framework-backed `GTlsDatabase`).
* Real-device (`device-arm64`) build is untested; needs signing and a
  review of the `pipe2`/`dup3` notes in `compat/ios-compat.h`.
* JID stringprep uses a casefold fallback (`-Dicu=disabled`); full
  ICU-based stringprep/IDNA would require cross-compiling ICU.
* OpenPGP plugin: not ported (GPGME on iOS is impractical).

## Layout

| Path | Purpose |
| --- | --- |
| `build-deps.sh` | Cross-compiles the dependency stack into `prefix/<target>`: GLib (+libffi, pcre2, proxy-libintl), libgee, gdk-pixbuf (+libpng), OpenSSL, glib-networking, libgpg-error, libgcrypt, protobuf-c, libomemo-c, libsrtp2, libpsl, libsoup3 (+nghttp2). Generates the Meson cross file. |
| `build-core.sh` | Builds Dino (core + crypto-vala + omemo + http-files plugins + the bridge) against that prefix: `-Dui=disabled -Dicu=disabled -Dios-bridge=enabled -Dplugin-omemo=enabled -Dplugin-http-files=enabled`. |
| `bridge/` | `dino_ios.vala`: boots a non-GTK `Dino.Application`, registers the statically linked plugins, and exposes a C API (`dinoios.h`) — events flow to Swift as JSON lines on a single callback. `tls_glue.c` statically registers the OpenSSL GIO TLS backend. |
| `app/` | SwiftUI app (account setup, conversation list, chat view with OMEMO toggle). `build-app.sh` builds `DinoPoc.app` with plain `swiftc` (no Xcode project) and can install + launch it in the Simulator. |
| `compat/ios-compat.h` | Declares symbols (`pipe2`, `dup3`, `getentropy`) that recent iOS SDKs export from libSystem but hide in headers, which otherwise breaks autoconf/Meson feature detection. |

## Reproduce

```sh
ios/build-deps.sh sim-arm64        # ~15 min, downloads sources
ios/build-core.sh sim-arm64
ios/app/build-app.sh run           # boots an iPhone simulator
```

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

## Next steps

1. MUC: join/leave UI, occupant list; the core MucManager already syncs
   bookmarks.
2. Message corrections and reactions (services already running).
3. Push notifications (XEP-0357 + proxy + NSE) — the big one.
4. iOS-native trust store via a custom `GTlsDatabase`.
5. Device build + signing; CI for the cross-compile.

Already done beyond the basics: contact management (roster, presence,
subscription requests), sign in/out with stable OMEMO identity, avatars,
conversation previews/unread counts/read markers (XEP-0333), typing
notifications (XEP-0085), and file transfers (HTTP upload via libsoup,
OMEMO-encrypted aesgcm files, inline image previews, tap-to-download;
note: GIO mime sniffing is extension-based on iOS — no shared-mime-info).
