#!/usr/bin/env bash
# Configure, build and install one CMake project for wasm32-wasip1 into WEBBY_WASI_SYSROOT.
# usage: cmake-dep.sh SRC BUILD [cmake -D args...]
# env: CMAKE_DEP_TARGETS (space-separated) builds only those targets, then installs (for projects whose tools do not build).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=$1; build=$2; shift 2
# The toolchain's flags only reach a fresh configure (CMake caches them), so a changed toolchain or compat link list
# starts the build directory over.
stamp=$(cat "$here/cmake/wasi.cmake" "$here/compat/build.sh" | sha256sum | cut -d' ' -f1)
if [ "$(cat "$build/.webby-toolchain" 2>/dev/null)" != "$stamp" ]; then rm -rf "$build"; mkdir -p "$build"; echo "$stamp" > "$build/.webby-toolchain"; fi
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$here/cmake/wasi.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${WEBBY_WASI_SYSROOT:?}" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF "$@" > "$build.configure.log" 2>&1 \
  || { tail -30 "$build.configure.log"; exit 1; }
cmake --build "$build" ${CMAKE_DEP_TARGETS:+--target $CMAKE_DEP_TARGETS} > "$build.build.log" 2>&1 || { grep -m5 -A5 "error" "$build.build.log"; exit 1; }
cmake --install "$build" > /dev/null
echo "installed $(basename "$src")"
