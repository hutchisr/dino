#!/usr/bin/env bash
# Build libdinopoc.a: Vala -> C (host valac), C -> arm64-ios (clang), ar.
set -euo pipefail

TARGET="${1:-sim-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PREFIX="$ROOT/prefix/$TARGET"
OUT="$HERE/out-$TARGET"
MIN_IOS=16.0

case "$TARGET" in
  sim-arm64)    SDK=iphonesimulator; TRIPLE="arm64-apple-ios${MIN_IOS}-simulator" ;;
  device-arm64) SDK=iphoneos;        TRIPLE="arm64-apple-ios${MIN_IOS}" ;;
esac
SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" -f clang)"

rm -rf "$OUT" && mkdir -p "$OUT/c"

valac --ccode --directory "$OUT/c" -H "$OUT/dino_poc.h" --library dinopoc \
  --vapidir "$PREFIX/share/vala/vapi" \
  --vapidir "$(dirname "$ROOT")/xmpp-vala/vapi" \
  --pkg gio-2.0 --pkg gee-0.8 --pkg xmpp-vala \
  "$HERE/dino_poc.vala"

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
CFLAGS="$(pkg-config --cflags gio-2.0 gee-0.8 gdk-pixbuf-2.0) -I$PREFIX/include"

for f in $(find "$OUT/c" -name '*.c') "$HERE/poc_glue.c"; do
  "$CLANG" -target "$TRIPLE" -isysroot "$SDKPATH" $CFLAGS -I"$OUT" \
    -Wno-incompatible-pointer-types -Wno-discarded-qualifiers \
    -c "$f" -o "$OUT/$(basename "$f" .c).o"
done

"$(xcrun --sdk "$SDK" -f ar)" rcs "$OUT/libdinopoc.a" "$OUT"/*.o
echo "built $OUT/libdinopoc.a"
