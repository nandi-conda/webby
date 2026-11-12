#!/usr/bin/env bash
# Configure and build Ladybird (with webby's patches) for wasm32-wasip1.
# usage: build-engine.sh LADYBIRD_SRC BUILD_DIR [targets...]   (default target: js)
# env: WEBBY_CCACHE=0 (no ccache), WEBBY_UI_DIR (default ./ui), ENABLE_GUI_TARGETS (ON for LibWeb and webby-render), WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (dependencies from deps/), RUSTUP_TOOLCHAIN (Ladybird's, with wasm32-wasip1)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$1; build=$2; shift 2
targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=(js)
# NB: pixi's own rust has no wasm32-wasip1 standard library. rustup's proxies use Ladybird's rust-toolchain.toml.
if [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/rustup" ]; then export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"; fi
# The Rust runtime's build script compiles the C interpreter (patches/0003) with cc-rs, which needs wasi-sdk's clang.
export CC_wasm32_wasip1="${CC_wasm32_wasip1:-$WASI_SDK_PREFIX/bin/clang}" AR_wasm32_wasip1="${AR_wasm32_wasip1:-$WASI_SDK_PREFIX/bin/llvm-ar}"
# Configured every time (cheap when nothing changed), so a change to these options reaches an existing build directory.
# ccache, when there is one, wraps the compilers (ci/engine.sh keeps its directory in the job's cache).
mkdir -p "$build"
launcher=()
if command -v ccache > /dev/null && [ "${WEBBY_CCACHE:-1}" != 0 ]; then
  launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi
cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$here/cmake/wasi.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_GUI_TARGETS="${ENABLE_GUI_TARGETS:-OFF}" \
    -DENABLE_JS_JIT=OFF \
    -DENABLE_LTO_FOR_RELEASE=OFF \
    -DENABLE_LAGOM_CCACHE=OFF \
    -DENABLE_INSTALL_HEADERS=OFF \
    -DENABLE_CLANG_PLUGINS=OFF \
    -DLADYBIRD_ENABLE_CPPTRACE=OFF \
    -DENABLE_NETWORK_DOWNLOADS=OFF \
    -DRUST_TARGET_TRIPLE=wasm32-wasip1 \
    -DWEBBY_UI_DIR="${WEBBY_UI_DIR:-$here/ui}" \
    "${launcher[@]}" > "$build/configure.log" || { tail -50 "$build/configure.log"; exit 1; }
cmake --build "$build" --target "${targets[@]}"
