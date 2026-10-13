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

# Only the pinned commit is fetched (no history), which keeps the download small.
if [ ! -d "$LADYBIRD_DIR/.git" ]; then
    git init -q "$LADYBIRD_DIR"
    git -C "$LADYBIRD_DIR" remote add origin https://github.com/LadybirdBrowser/ladybird.git
fi

cd "$LADYBIRD_DIR"
if [ "$(git rev-parse -q --verify HEAD || true)" != "$LADYBIRD_COMMIT" ]; then
    for attempt in 1 2 3 4; do
        git fetch -q --depth 1 origin "$LADYBIRD_COMMIT" && break
        sleep $((attempt * 5))
    done
    git checkout -q -f FETCH_HEAD
fi

# Our Ladybird patches: 0001 teaches UI/ about the Flutter frontend, 0002 adds Web Authentication (passkeys), 0003
# adds RequestServer's offline (cache-only) mode, 0004 lets image/media documents load the resource they show despite
# its CSP, 0005 to 0010 get the Android build working and running (plain helper executables, HarfBuzz/FreeType for
# Skia, bit-rotted Android code, a primitive storage cage that fits a 39-bit address space, a writable temp dir), 0011 adds the microphone permission prompt, 0012 builds the Cranelift WebAssembly JIT for Android, 0013 gives the Android Compositor an ANGLE GLES backend for WebGL, 0014 keeps WebGL bindings across canvas resizes, 0015 lets webby turn off the spare WebContent process, 0016 passes MIMALLOC_* settings on to the helper processes, 0017 stops pages with a <video> from repainting every frame, 0019 lets null cells in grid-template-areas size the explicit grid (`". ."` is two columns). When the patch set changes, the tree goes back to the pinned commit first so every patch
# applies to pristine sources.
PATCHES_STAMP="$(cat "$ROOT"/patches/*.patch | sha256sum | cut -d' ' -f1)"
if [ "$(cat .git/webby-patches 2>/dev/null || true)" != "$PATCHES_STAMP" ]; then
    git reset -q --hard HEAD
    git clean -q -fd -- AK Libraries Meta Services UI
    for patch in "$ROOT"/patches/*.patch; do
        git apply "$patch"
    done
    echo "$PATCHES_STAMP" > .git/webby-patches
fi
# Point UI/Flutter at our native shim.
ln -sfn "$ROOT/native" UI/Flutter

export CC CXX
python3 Meta/ladybird.py vcpkg --preset Release
export VCPKG_ROOT="$LADYBIRD_DIR/Build/vcpkg-release"
export PATH="$PATH:$VCPKG_ROOT"

# scripts/android/build_ladybird.sh reuses the checkout, patches and vcpkg tool, then configures its own build.
if [ -n "${WEBBY_PREPARE_ONLY:-}" ]; then
    exit 0
fi

if [ ! -f Build/release/build.ninja ]; then
    cmake --preset Release -S . -B Build/release \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DLADYBIRD_UI_FLUTTER=ON -DBUILD_TESTING=OFF \
        -DENABLE_LTO_FOR_RELEASE=OFF -DLAGOM_USE_LINKER="$LINKER"
fi
# Without this Ladybird builds with -march=native, and the result crashes with SIGILL on CPUs other than the build
# host's. x86-64-v3 is what Ladybird's own CI targets.
cmake -S . -B Build/release -DENABLE_CI_BASELINE_CPU=ON

# `ladybird` is libwebby.so here; it depends on WebContent, RequestServer, ImageDecoder and the resource files.
cmake --build Build/release --target ladybird
# WasmCompiler looks for cranelift-compiler next to itself; Ladybird leaves it in bin/, which runtime tarballs don't
# ship, and without it every WebAssembly module runs in the (much slower) interpreter.
if [ -f Build/release/bin/cranelift-compiler ]; then
    cp -f Build/release/bin/cranelift-compiler Build/release/libexec/cranelift-compiler
fi

echo
echo "Ladybird prefix: $LADYBIRD_DIR/Build/release"
echo "Run the app with: scripts/run_app.sh"
