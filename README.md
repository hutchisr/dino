<img src="ios/app/AppIcon.png" width="80">

# Gecko

Gecko is an XMPP messaging app for iOS and Apple Silicon macOS, built with
SwiftUI on top of [Dino](https://dino.im)'s messaging core. It supports OMEMO
encryption, group chats, file transfers, push notifications and more.

Gecko is a fork of Dino — the Vala/GTK XMPP client for Linux. GTK doesn't run
on iOS or Mac Catalyst, so this tree keeps Dino's non-UI core (the Vala/GLib
service stack: `libdino`, `xmpp-vala`, `qlite`, `crypto-vala`, and the OMEMO +
HTTP-upload plugins), cross-compiles it as static libraries, and puts a native
SwiftUI front end on top through a small C/Vala bridge. The desktop GTK UI has
been removed; iPhone and Mac Catalyst use the same SwiftUI application.

Status
------
Working end to end against real servers:

- Login over SCRAM/STARTTLS, roster and bookmark sync, contact management
- One-to-one and group chats (MUC), with per-sender avatars and nicks
- **OMEMO** encryption (statically linked libomemo-c), with a stable device identity
- File transfers over HTTP upload, OMEMO-encrypted, with inline image previews
- Reactions (XEP-0444), corrections (XEP-0308), replies (XEP-0461),
  read markers (XEP-0333), typing notifications (XEP-0085)
- **Notifications** — iOS uses XEP-0357 through the bundled push proxy and an
  on-device Notification Service Extension. While the Mac Catalyst app is
  running, it posts local notifications from its live XMPP stream and applies
  each conversation's off / mentions-only setting before delivery.

Not implemented: voice/video calls (`plugin-rtp`/`plugin-ice` need GStreamer's
iOS binaries), OpenPGP, and ICU-based JID stringprep (a casefold fallback is
used instead).

There is no public release yet; iOS builds are distributed via TestFlight and
sideloading. macOS uses an Apple Silicon Mac Catalyst build.

Build
-----
Requires macOS with Xcode 26. iOS and Mac Catalyst currently target version 26
or later.

For an iOS Simulator:

    ios/build-deps.sh sim-arm64
    ios/build-core.sh sim-arm64
    ios/app/build-app.sh run sim-arm64

For an Apple Silicon Mac:

    ios/build-deps.sh catalyst-arm64
    ios/build-core.sh catalyst-arm64
    ios/app/build-app.sh run catalyst-arm64

Use `device-arm64` to build for a physical iPhone. Once the matching static
prefix exists under `ios/prefix/<target>`, you can also open `Gecko.xcodeproj`
and build the shared `Gecko` scheme for iPhone, Simulator, or Mac Catalyst.

Unit tests for the pure Swift helpers run on the host, without a Simulator:

    cd ios/app/GeckoKit && swift test

Resources
---------
- [`ios/PORTING.md`](ios/PORTING.md) — the port bible: cross-compile, bridge
  design, OMEMO, push, NSE phases, and the changes made to the upstream Vala tree.
- [`AGENTS.md`](AGENTS.md) — orientation for working in this repository.
- [`ios/PRIVACY.md`](ios/PRIVACY.md), [`ios/app/TESTFLIGHT.md`](ios/app/TESTFLIGHT.md) — privacy and release notes.
- Upstream: the [Dino website](https://dino.im), its
  [wiki](https://github.com/dino/dino/wiki), and the `chat@dino.im` XMPP channel.

License
-------
    Gecko - XMPP messaging app for Apple platforms
    Copyright (C) 2026 Gecko contributors

    Based on Dino - XMPP messaging app using GTK/Vala
    Copyright (C) 2016-2025 Dino contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
