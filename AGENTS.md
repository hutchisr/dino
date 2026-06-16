# AGENTS.md

Orientation for AI agents (and humans) working in this repository.

## What this repo is

This is a fork of **[Dino](https://dino.im)** — an XMPP messaging app originally
written in Vala/GTK4 for Linux — ported to **iOS** under the product name
**Gecko**. GTK does not run on iOS, so the port keeps Dino's non-UI core (the
Vala/GLib service stack) and puts a native **SwiftUI** front end on top, bridged
by a small C/Vala shim.

The desktop GTK UI has been removed (`main/` is gone; commit _"Remove
desktop-only code; Gecko is iOS-only now"_). **Treat this tree as iOS-only.**
The upstream `README.md` still describes desktop Dino and is kept for
provenance — it does not reflect this fork's focus.

License: **GPL-3.0** (`LICENSE`). The App-Store distribution plan keeps GPLv3
(libomemo-c stays via its App Store carve-out); see the licensing memory.

The canonical deep-dive on the port is **[`ios/PORTING.md`](ios/PORTING.md)** —
read it for the cross-compile, the bridge design, OMEMO/push details, and the
list of changes made to the upstream Vala tree. This file is the shorter "how to
work here" companion.

## Architecture in one screen

```
┌─────────────────────────────────────────────┐
│ SwiftUI app  (ios/app/Sources/*.swift)       │  GeckoApp.swift = the UI
│   AppModel (Model.swift) ── @Published state │  Model.swift   = state + event decode
└───────────────▲──────────────┬──────────────┘
                │ JSON events   │ C calls
┌───────────────┴──────────────▼──────────────┐
│ Bridge  (ios/bridge/dino_ios.vala)           │  boots a non-GTK Dino.Application,
│   one callback emits events as JSON lines    │  registers static plugins, exposes a C API
└───────────────▲──────────────────────────────┘
                │ static-linked
┌───────────────┴──────────────────────────────┐
│ libdino core + xmpp-vala + qlite + crypto-vala│  cross-compiled to static libs
│ + omemo & http-files plugins + GLib stack     │  (ios/prefix/<target>)
└───────────────────────────────────────────────┘
```

- The bridge runs `GApplication.run()` on a **dedicated thread**; Swift→core
  calls marshal onto the GLib main context via `Idle.add`; events come back on
  the GLib thread and are hopped to the main queue in Swift. (Connect-time async
  work fired from connect signals doesn't complete on iOS — drive it from a Swift
  timer; see the connect-time-async memory.)
- Everything is **statically linked** (iOS forbids dlopen of unsigned dylibs);
  plugins are registered by direct instantiation, not Dino's GModule loader.

## Directory map

| Path | What |
| --- | --- |
| `ios/PORTING.md` | **Read first.** The authoritative port doc. |
| `ios/build-deps.sh` | Cross-compiles the GLib/OpenSSL/gcrypt/omemo/soup dependency stack into `ios/prefix/<target>` (~15 min, downloads sources). |
| `ios/build-core.sh` | Builds Dino core + plugins + the bridge against that prefix. |
| `ios/bridge/dino_ios.vala` | The C API bridge. `path` events, `content_item_json`, `notify[...]` emitters, the `DINO_*` automation hooks live around here. |
| `ios/app/Sources/` | The SwiftUI app. `GeckoApp.swift` (views, ~3k lines), `Model.swift` (`AppModel`, event decode, `ChatMessage`), plus per-screen files. |
| `ios/app/GeckoKit/` | SwiftPM package of **pure, dependency-free helpers** — unit-tested on the host. See below. |
| `ios/app/GeckoXMPP/` | **Scaffold only** (empty `Core/`, `Stanza/`). Reserved for in-progress clean-room/native-Swift XMPP work; nothing depends on it yet. |
| `ios/app/build-app.sh` | Builds `Gecko.app` with plain `swiftc` (no Xcode project). `run` installs+launches in the Simulator. |
| `ios/app/deploy-phone.sh` | Build + re-sign + install on a physical iPhone via `devicectl`. |
| `ios/app/deploy-testflight.sh` | Archive + upload to TestFlight. |
| `ios/nse/` | Notification Service Extension — on-device push decrypt/filter (`NotificationService.swift`, `NSEFetcher.swift`). |
| `ios/push-proxy/` | XEP-0357 → APNs push proxy (Python, containerized, runs on k8s namespace `gecko`). Has its own tests. |
| `ios/udid-enroll/`, `ios/dist-host/` | Ad-hoc device enrollment + IPA distribution host (containerized). |
| `crypto-vala/ libdino/ plugins/ qlite/ xmpp-vala/` | Upstream Vala sources (cross-compiled for iOS). |

## Build, run, test

```sh
# One-time per target: build the dependency + core stacks (slow)
ios/build-deps.sh sim-arm64          # or device-arm64
ios/build-core.sh sim-arm64

# Build + run the app in the Simulator (fast; recompiles only Swift)
ios/app/build-app.sh run sim-arm64   # ACTION defaults to "build", TARGET to "sim-arm64"

# Deploy to a physical device (phone must be connected; on request only)
ios/app/deploy-phone.sh "iPhone 17 Pro"

# Unit tests — host, fast, no Simulator:
cd ios/app/GeckoKit && swift test
# (xcodebuild test runs the same package on the Simulator if you need UIKit-gated paths)

# Lint (config tuned in .swiftlint.yml — bug rules on, style noise off):
swiftlint
```

## Conventions

- **GeckoKit = one source of truth, two compilations.** Pure helpers (scroll
  math, message formatting, image encoding/sizing) live in
  `GeckoKit/Sources/GeckoKit/*.swift`. `build-app.sh` **globs those files
  straight into the app** alongside `Sources/*.swift`, and `swift test`
  exercises the *same* files on the host. So: put anything testable and
  UI/UIKit/bridge-free in GeckoKit and add tests; the app gets it for free.
  UIKit/ImageIO-only code goes behind `#if canImport(UIKit)` (excluded from the
  host test build) — keep the pure parts ungated so they stay testable (see
  `ImageThumbnail.swift`: `fit` is ungated and tested, the decode is gated).
- **Swift style**: match the surrounding code — short local names (`e`, `c`,
  `jid`, `me`) are idiomatic here and the linter allows them; `AppModel` is
  intentionally large; trailing commas in multi-line literals are intentional.
- **Commit messages**: `area: imperative summary — elaboration`, e.g.
  `ios: reserve image row height so chats open pinned to the bottom`,
  `ios/nse: ...`, `push-proxy: ...`. Body explains the *why*. Commit only when
  asked; the default branch is `master`, current work branch is `libdino`.
- **Vala changes must stay desktop-neutral in spirit** (guarded by feature
  options); see `ios/PORTING.md` § "Changes to the main tree".

## Working in the Simulator (hard-won operational notes)

- **Headless automation**: the app reads `DINO_*` env vars (passed via the
  `SIMCTL_CHILD_` prefix) to drive itself for testing — e.g.
  `DINO_AUTOPEER=jid` (start+open a chat), `DINO_AUTOOPEN=jid` (navigate to an
  existing chat), `DINO_AUTOSEND=text`, `DINO_AUTOSENDFILE=1` (send a generated
  test image), `DINO_AUTOOMEMO=1`, `DINO_LOG_XMPP=all`. Defined in
  `Model.swift` (`setupAutomationHooks` / `runConnectedAutomation`).
- **Logs**: Swift `NSLog` shows up in **both** `xcrun simctl spawn booted log
  stream --predicate 'process == "Gecko"'` **and** `simctl launch
  --console-pty`. The Vala `g_message` lines go to **stderr only** (console).
  For scroll/timing debugging, temporary `NSLog` + a `log stream` grep is the
  proven loop (the Simulator can't inject scroll *drags*, so momentum/mid-flick
  behavior is **device-only** — see the scroll-button memory).
- **Refreshing a build: `simctl install` over the top — never `uninstall`.**
  Uninstall **wipes the app's data container, including the logged-in XMPP
  account** (you'll have to log back in). Install-over-the-top preserves login.
- **Stale-binary trap**: `simctl install` lands in a new bundle container and
  old ones linger; after installing, confirm the *running* code is fresh by
  grepping the binary for a marker string
  (`strings <Bundle>/Gecko.app/Gecko | grep MYMARKER`) before trusting a "no
  log output" result.
- **Test accounts**: `geckotest@xmpp.is` (the app account) with peer
  `anemone@xmpp.is` (image-heavy chat). Live secrets are in
  **`credentials.local.txt`** (gitignored) — read it **only when the user
  explicitly directs**, never scan around for credentials. Note: xmpp.is HTTP
  upload has been flaky/unavailable — outgoing image sends may not complete;
  inject a local file message for layout testing instead of relying on upload.
- **Phone deploys are on request only**; default to Simulator verification.

## State of the work

Working end-to-end (Simulator, against real servers): full libdino stack,
login (SCRAM/STARTTLS), roster/bookmark sync, 1:1 + MUC messaging, **OMEMO**
(static libomemo-c), HTTP file transfer with inline image previews, reactions
(XEP-0444), corrections (0308), replies (0461), read/typing markers (0333/0085),
account settings, avatars, and **push notifications** (XEP-0357 → the
`ios/push-proxy` → APNs). The **NSE** decrypts/filters pushes on-device
(banner suppression for muted chats is gated on an Apple entitlement). Verified
device deployment + a TestFlight build exist.

Recent focus has been **chat UI polish in `GeckoApp.swift` + `GeckoKit`**:
pending (unsent) message badges; reliable open-at-bottom scrolling
(`ChatScroll.swift`, unit-tested); downsampled+cached image thumbnails for
smooth scrolling (`ImageThumbnail.swift`); a morphing attach menu; and — most
recently — reserving an image row's final height up front (from a cheap header
read) so a chat that's pinned to the bottom stays pinned when the image decodes,
instead of jumping to the new image's top. One **known-unsolved** item: the
scroll-to-bottom button's smooth glide when tapped mid-flick (device-only;
documented in the scroll-button memory, reverted to baseline).

Not done: voice/video calls (`plugin-rtp`/`plugin-ice` — needs GStreamer iOS
binaries), ICU stringprep, OpenPGP, and CI for the cross-compile. See
`ios/PORTING.md` § "Next steps".

## Deeper references

- `ios/PORTING.md` — the port bible (build, bridge, OMEMO, push, NSE phases, gotchas).
- `ios/app/TESTFLIGHT.md`, `ios/PRIVACY.md` — release + privacy notes.
- `ios/push-proxy/README.md`, `ios/nse/` — push subsystem.
- Project memory (auto-loaded): see `MEMORY.md` under the Claude project dir for
  the running log of dead ends and hard-won facts (push setup/dedup, connection
  stability, gdk-pixbuf PNG-only, scroll facts, licensing path, …). Memories
  reflect what was true when written — verify a named file/flag still exists
  before relying on it.
