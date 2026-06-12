#!/usr/bin/env bash
# Build Dino's core (qlite, xmpp-vala, libdino) for iOS as static libraries.
# Run ./build-deps.sh first to populate ios/prefix/<target>.
set -euo pipefail

TARGET="${1:-sim-arm64}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$ROOT")"
PREFIX="$ROOT/prefix/$TARGET"
CROSS="$ROOT/cross/$TARGET.ini"
BDIR="$ROOT/build-$TARGET"

meson setup "$BDIR" "$SRC" --cross-file "$CROSS" --prefix "$PREFIX" \
  --default-library static --buildtype debugoptimized \
  -Dui=disabled -Dicu=disabled -Dios-bridge=enabled \
  -Dplugin-http-files=enabled -Dplugin-ice=disabled -Dplugin-omemo=enabled \
  -Dplugin-openpgp=disabled -Dplugin-rtp=disabled -Dplugin-notification-sound=disabled \
  "${@:2}"
ninja -C "$BDIR"
ninja -C "$BDIR" install
