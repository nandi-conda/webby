#!/usr/bin/env bash
# Host wasm-opt with SpillPointers taught to spill i64 locals too (binaryen-webby.patch). LibGC's conservative scan
# reads the shadow stack in linear memory but cannot see wasm locals, so every linked program runs --spill-pointers:
# live i32 locals (pointers) and i64 locals (NaN-boxed JS values, low 32 bits an address) are stored to the shadow
# stack before each call. wasi.cmake runs it after every link when $WEBBY_WASI_SYSROOT/bin/webby-wasm-opt exists.
# Also: tail calls restore the spill area (the interpreter dispatches by return_call), and --stack-check takes
# --pass-arg=stack-check-size@N so a WASI program is checked without calling __set_stack_limits.
# usage: binaryen.sh WORK PREFIX
set -euo pipefail
work=$1; prefix=$2; here=$(cd "$(dirname "$0")" && pwd)
src=$work/binaryen
[ -d "$src" ] || git clone -q --depth 1 --branch version_121 https://github.com/WebAssembly/binaryen "$src"
# The work dir is cached between runs: when the patch changed, the old one comes off before the new one goes on.
if ! cmp -s "$here/binaryen-webby.patch" "$work/binaryen-applied.patch"; then
  git -C "$src" checkout -q -- .
  git -C "$src" apply "$here/binaryen-webby.patch"
  cp "$here/binaryen-webby.patch" "$work/binaryen-applied.patch"
fi
cmake -S "$src" -B "$work/binaryen-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_WERROR=OFF \
  -DBUILD_STATIC_LIB=ON > "$work/binaryen-cmake.log"
ninja -C "$work/binaryen-build" wasm-opt > "$work/binaryen-build.log"
mkdir -p "$prefix/bin"; cp "$work/binaryen-build/bin/wasm-opt" "$prefix/bin/webby-wasm-opt"
echo "webby-wasm-opt in $prefix/bin"
