#!/usr/bin/env bash
set -euxo pipefail

export PATH="$SRC_DIR/flutter/bin:$PATH"
# Keep the Flutter tool's config and pub cache inside the build tree.
export HOME="$SRC_DIR/.home" PUB_CACHE="$SRC_DIR/.pub-cache"
mkdir -p "$HOME"
git config --global --add safe.directory '*'
flutter config --no-analytics --enable-linux-desktop >/dev/null

# Same toolchain setup as scripts/pixi_start.sh, with the host prefix's GTK. The runner links epoxy and fontconfig
# directly so they're loaded from the env (libflutter_linux_gtk.so needs them too).
export CC=clang CXX=clang++
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include"
export LDFLAGS="-fuse-ld=lld -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib \
  -Wl,--push-state,--no-as-needed -lepoxy -lfontconfig -Wl,--pop-state"

cd "$SRC_DIR/app"
# The Linux runner is stock `flutter create` output, so it's generated rather than checked in.
[ -d linux ] || flutter create --platforms=linux --project-name webby --org dev.webby .
# Give the window the webby icon.
runner=linux/runner/my_application.cc
grep -q webby.png "$runner" ||
  sed -i "/gtk_window_set_default_size(window, 1280, 720);/r $RECIPE_DIR/window_icon.inc" "$runner"
grep -q webby.png "$runner"
flutter build linux --release

mkdir -p "$PREFIX/lib/webby" "$PREFIX/bin"
cp -a build/linux/x64/release/bundle/. "$PREFIX/lib/webby/"
install -m 755 "$RECIPE_DIR/webby.sh" "$PREFIX/bin/webby"

# Icons, rendered from icons/*.svg; the small variant is drawn for 16-32 px.
icons="$PREFIX/share/icons/hicolor"
for s in 16 24 32 48 64 128 256 512; do
  svg="$SRC_DIR/icons/webby.svg"
  [ "$s" -le 32 ] && svg="$SRC_DIR/icons/webby-small.svg"
  mkdir -p "$icons/${s}x${s}/apps"
  rsvg-convert -w "$s" -h "$s" "$svg" -o "$icons/${s}x${s}/apps/dev.webby.webby.png"
done
install -Dm644 "$SRC_DIR/icons/webby.svg" "$icons/scalable/apps/dev.webby.webby.svg"
install -Dm644 "$icons/256x256/apps/dev.webby.webby.png" "$PREFIX/lib/webby/data/webby.png"

# App menu entry, installed by menuinst (pixi global install, conda install).
install -Dm644 "$RECIPE_DIR/menu.json" "$PREFIX/Menu/webby.json"
install -Dm644 "$icons/256x256/apps/dev.webby.webby.png" "$PREFIX/Menu/webby.png"
