#!/usr/bin/env bash
# Build Dino's core (qlite, xmpp-vala, libdino) as static libraries for iOS
# and Mac Catalyst. Run ./build-deps.sh first for the same target.
set -euo pipefail

TARGET="${1:-sim-arm64}"
case "$TARGET" in
  sim-arm64|device-arm64|catalyst-arm64) ;;
  *) echo "unknown target $TARGET" >&2; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$ROOT")"
PREFIX="$ROOT/prefix/$TARGET"
CROSS="$ROOT/cross/$TARGET.ini"
BDIR="$ROOT/build-$TARGET"

if [ ! -f "$CROSS" ]; then
  echo "missing $CROSS; run ./build-deps.sh $TARGET first" >&2
  exit 1
fi
meson setup "$BDIR" "$SRC" --cross-file "$CROSS" --prefix "$PREFIX" \
  --default-library static --buildtype debugoptimized \
  -Dui=disabled -Dicu=disabled -Dios-bridge=enabled \
  -Dplugin-http-files=enabled -Dplugin-ice=disabled -Dplugin-omemo=enabled \
  -Dplugin-rtp=disabled \
  "${@:2}"
ninja -C "$BDIR"
ninja -C "$BDIR" install
