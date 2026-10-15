#!/usr/bin/env bash
set -euxo pipefail

# The Nim front end, built as scripts/pixi_nim.sh builds it: no -d:ssl (Nim's OpenSSL setup would load a libcrypto
# before libwebby's own), the env's GTK through the rpath, and libstdc++ linked in so the env's loads first.
export HOME="$SRC_DIR/.home"
# GTK's flags come from pkg-config at compile time (a failed lookup would end up in the C compiler's arguments).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
pkg-config --cflags --libs gtk+-3.0 > /dev/null
mkdir -p "$HOME" "$PREFIX/lib/webby" "$PREFIX/bin"
nim c -d:release --hints:off --warnings:off --cc:clang --nimcache:"$SRC_DIR/.nimcache" \
  --passL:"-fuse-ld=lld -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib -Wl,--no-as-needed -lstdc++ -Wl,--as-needed" \
  -o:"$PREFIX/lib/webby/webby" "$SRC_DIR/nim/webby.nim"
install -m 755 "$RECIPE_DIR/webby.sh" "$PREFIX/bin/webby"
# The launcher's FONTCONFIG_FILE; it goes in webby-ladybird's share/Lagom/fonts so the sandboxed helpers can read it.
mkdir -p "$PREFIX/lib/webby-ladybird/share/Lagom/fonts"
sed "s|@PREFIX@|$PREFIX|" "$RECIPE_DIR/webby-fonts.conf" > "$PREFIX/lib/webby-ladybird/share/Lagom/fonts/webby-fonts.conf"

# Icons, rendered from icons/*.svg; the small variant is drawn for 16-32 px.
icons="$PREFIX/share/icons/hicolor"
for s in 16 24 32 48 64 128 256 512; do
  svg="$SRC_DIR/icons/webby.svg"
  [ "$s" -le 32 ] && svg="$SRC_DIR/icons/webby-small.svg"
  mkdir -p "$icons/${s}x${s}/apps"
  rsvg-convert -w "$s" -h "$s" "$svg" -o "$icons/${s}x${s}/apps/dev.webby.webby.png"
done
install -Dm644 "$SRC_DIR/icons/webby.svg" "$icons/scalable/apps/dev.webby.webby.svg"

# App menu entry, installed by menuinst (pixi global install, conda install).
install -Dm644 "$RECIPE_DIR/menu.json" "$PREFIX/Menu/webby.json"
install -Dm644 "$icons/256x256/apps/dev.webby.webby.png" "$PREFIX/Menu/webby.png"
