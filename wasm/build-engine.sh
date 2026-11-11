#!/usr/bin/env bash
# Configure and build Ladybird (with webby's patches) for wasm32-wasip1.
# usage: build-engine.sh LADYBIRD_SRC BUILD_DIR [targets...]   (default target: js)
# env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (dependencies from deps/), RUSTUP_TOOLCHAIN (Ladybird's, with wasm32-wasip1)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$1; build=$2; shift 2
targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=(js)
if [ ! -f "$build/build.ninja" ]; then
  cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$here/cmake/wasi.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_GUI_TARGETS=OFF \
    -DENABLE_JS_JIT=OFF \
    -DENABLE_LTO_FOR_RELEASE=OFF \
    -DENABLE_LAGOM_CCACHE=OFF \
    -DENABLE_INSTALL_HEADERS=OFF \
    -DENABLE_CLANG_PLUGINS=OFF \
    -DLADYBIRD_ENABLE_CPPTRACE=OFF \
    -DENABLE_NETWORK_DOWNLOADS=OFF \
    -DRUST_TARGET_TRIPLE=wasm32-wasip1
fi
cmake --build "$build" --target "${targets[@]}"
