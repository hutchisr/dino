# Dino on iOS

This directory contains a working proof-of-concept port of Dino's core to
iOS. GTK4 does not run on iOS, so the approach is:

* Cross-compile the non-UI core — `qlite`, `xmpp-vala`, `libdino` — and its
  GLib stack as **static libraries** for iOS.
* Put a native **SwiftUI** front end on top, talking to the Vala core
  through a small C bridge.

## Status: what works today

Verified in the iOS Simulator (arm64) on 2026-06-12:

* GLib 2.84 main loop, GObject, GIO running inside an iOS app.
* `qlite`, `xmpp-vala`, `libdino` compile and link (Vala → C on the host,
  C → arm64-ios via clang, driven by Meson cross files).
* Real XMPP connectivity end-to-end: DNS SRV lookup → TCP → STARTTLS with
  certificate verification (glib-networking's OpenSSL backend, statically
  registered) → stream negotiation → SASL. A login attempt against
  jabber.org round-trips and the server's auth response is surfaced in the
  SwiftUI app. Roster fetch and message send/receive are wired in the PoC
  bridge (`poc/dino_poc.vala`) for use with real credentials.

## Layout

| Path | Purpose |
| --- | --- |
| `build-deps.sh` | Cross-compiles the dependency stack into `prefix/<target>`: GLib (+libffi, pcre2, proxy-libintl subprojects), libgee, gdk-pixbuf (+libpng), OpenSSL, glib-networking. Generates the Meson cross file. |
| `build-core.sh` | Builds Dino's `qlite`/`xmpp-vala`/`libdino` against that prefix (`-Dui=disabled -Dicu=disabled`, all plugins off). |
| `compat/ios-compat.h` | Declares symbols (`pipe2`, `dup3`) that recent iOS SDKs export from libSystem but do not declare in headers, which otherwise breaks Meson feature detection. |
| `poc/` | `dino_poc.vala` — minimal login/roster/message bridge exposed as a C API; `build-poc.sh` compiles it to `libdinopoc.a`. |
| `app/` | SwiftUI shell. `build-app.sh` builds `DinoPoc.app` with `swiftc` (no Xcode project) and can install/launch it in the Simulator. |

Targets: `sim-arm64` (default, iOS Simulator) and `device-arm64` (untested;
needs signing and a CA-bundle/deployment-target review).

## Reproduce

```sh
ios/build-deps.sh sim-arm64        # ~10 min, downloads sources
ios/build-core.sh sim-arm64
ios/poc/build-poc.sh sim-arm64
ios/app/build-app.sh run           # boots an iPhone simulator
```

## Changes to the main tree

* `meson_options.txt` / `meson.build`: new `ui` and `icu` feature options.
  `-Dui=disabled` skips GTK4/libadwaita and `main/`; everything else is
  unchanged for desktop builds (both options default to enabled).
* `xmpp-vala/src/module/jid.vala`: when built with `-Dicu=disabled`, JID
  prep falls back to UTF-8 validation + casefolding (`NO_ICU` define)
  instead of full ICU stringprep/IDNA.

## Design notes / gotchas

* **Static everything.** iOS apps cannot dlopen unsigned dylibs; all libs
  are built `--default-library static`. Dino's GModule plugin loader is
  therefore unusable on iOS — plugins must be linked in and registered
  statically (the PoC doesn't load any).
* **TLS.** glib-networking is built with the OpenSSL backend.
  `poc/poc_glue.c` registers it without GIOModule scanning by calling
  `g_io_openssl_load(NULL)` (GLib ≥ 2.56 treats a NULL GTypeModule as
  static registration). The app bundles the host's `/etc/ssl/cert.pem` and
  points `SSL_CERT_FILE` at it; longer-term this should use the iOS trust
  store via a custom `GTlsDatabase`.
* **sqlite** comes from the iOS SDK (`libsqlite3.tbd`); a hand-written
  `sqlite3.pc` is dropped into the prefix by the build (regenerate it if
  the prefix is rebuilt from scratch).
* **pcre2 JIT** is disabled (no executable pages on iOS).
* **Vala cross-compiles cleanly**: host `valac` emits C, Meson compiles it
  with the iOS clang. No Vala changes were needed beyond the ICU fallback.

## Road to a real app

1. **Boot the full libdino service stack** (Database, StreamInteractor,
   managers) from the Swift side instead of the thin PoC bridge; store the
   sqlite DB in the app container. libdino already links — this is mostly
   the GLib.Application lifecycle and a richer C/Swift API (or generate
   Swift bindings from GIR).
2. **OMEMO**: cross-compile libgcrypt, libomemo-c, libsrtp2 and build
   `crypto-vala` + the omemo plugin minus its GTK UI (needs a meson split
   of plugin logic from UI, similar to the `ui` option).
3. **HTTP file upload**: cross-compile libsoup3 (or teach the plugin to use
   a GIO-only/NSURLSession path).
4. **Push notifications**: XEP-0357 server-side; iOS needs a push proxy and
   an NSE extension — the hardest product problem, as the TCP stream dies
   in the background.
5. **TLS trust**: replace the bundled CA pem with Security.framework-backed
   verification.
6. **Calls (plugin-rtp)**: GStreamer ships official iOS binaries, so this
   is feasible but a large follow-on project.
7. **Device target**: build `device-arm64`, check the `pipe2`/`dup3`
   runtime availability question in `compat/ios-compat.h`, sign, and test.
