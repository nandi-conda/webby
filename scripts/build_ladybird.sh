#!/usr/bin/env bash
# Builds Ladybird (LibWeb, LibJS, helper processes) plus libwebby.so, the C ABI the Flutter app loads.
#
# Usage: scripts/build_ladybird.sh            # clone/update into third_party/ladybird and build
#        LADYBIRD_DIR=/path/to/ladybird scripts/build_ladybird.sh
#
# Afterwards the Ladybird prefix (bin/, lib/libwebby.so, libexec/, share/Lagom) is $LADYBIRD_DIR/Build/release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LADYBIRD_DIR="${LADYBIRD_DIR:-$ROOT/third_party/ladybird}"
LADYBIRD_COMMIT="$(cat "$ROOT/LADYBIRD_COMMIT")"
CC="${CC:-clang-20}"
CXX="${CXX:-clang++-20}"
LINKER="${LINKER:-lld-20}"

if [ ! -d "$LADYBIRD_DIR/.git" ]; then
    git clone https://github.com/LadybirdBrowser/ladybird.git "$LADYBIRD_DIR"
fi

cd "$LADYBIRD_DIR"
if [ "$(git rev-parse HEAD)" != "$LADYBIRD_COMMIT" ]; then
    git fetch origin "$LADYBIRD_COMMIT" || git fetch origin
    git checkout -q "$LADYBIRD_COMMIT"
fi

# Teach Ladybird's UI/ about the Flutter frontend, and point UI/Flutter at our native shim.
if ! grep -q LADYBIRD_UI_FLUTTER UI/CMakeLists.txt; then
    git apply "$ROOT/patches/0001-ui-flutter-option.patch"
fi
ln -sfn "$ROOT/native" UI/Flutter

export CC CXX
python3 Meta/ladybird.py vcpkg --preset Release
export VCPKG_ROOT="$LADYBIRD_DIR/Build/vcpkg-release"
export PATH="$PATH:$VCPKG_ROOT"

if [ ! -f Build/release/build.ninja ]; then
    cmake --preset Release -S . -B Build/release \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DLADYBIRD_UI_FLUTTER=ON -DBUILD_TESTING=OFF \
        -DENABLE_LTO_FOR_RELEASE=OFF -DLAGOM_USE_LINKER="$LINKER"
fi

# `ladybird` is libwebby.so here; it depends on WebContent, RequestServer, ImageDecoder and the resource files.
cmake --build Build/release --target ladybird

echo
echo "Ladybird prefix: $LADYBIRD_DIR/Build/release"
echo "Run the app with: scripts/run_app.sh"
