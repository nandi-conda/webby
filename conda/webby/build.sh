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
flutter build linux --release

mkdir -p "$PREFIX/lib/webby" "$PREFIX/bin"
cp -a build/linux/x64/release/bundle/. "$PREFIX/lib/webby/"
install -m 755 "$RECIPE_DIR/webby.sh" "$PREFIX/bin/webby"
