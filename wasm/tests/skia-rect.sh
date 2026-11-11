#!/usr/bin/env bash
# Builds tests/skia-rect.cpp against the libskia.a deps/skia.sh installed and runs it under tools/wasi-run.py.
# usage: skia-rect.sh OUT_DIR [FONT.ttf]      env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT
# Writes OUT_DIR/skia-rect.wasm and OUT_DIR/skia-rect.png; exits non-zero if the drawn pixel is wrong.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sdk=${WASI_SDK_PREFIX:?}; sysroot=${WEBBY_WASI_SYSROOT:?}
mkdir -p "$1"; out=$(realpath "$1")
skia_cflags=$(sed -n "s|^Cflags: ||p" "$sysroot/lib/pkgconfig/skia.pc" | sed "s|\${prefix}|$sysroot|g")
emu="-D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID"
# shellcheck disable=SC2086
"$sdk/bin/clang++" --target=wasm32-wasip1 -O2 -std=c++20 -fno-exceptions -fno-rtti -mtail-call -msimd128 \
    -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false $emu \
    -isystem "$sysroot/include" -include "$sysroot/include/webby_wasi_compat.h" $skia_cflags \
    "$here/tests/skia-rect.cpp" -o "$out/skia-rect.wasm" \
    -L"$sysroot/lib" -lskia -lsetjmp -lwebby_wasi_compat \
    -lwasi-emulated-mman -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid
font=()
if [ $# -gt 1 ]; then cp "$2" "$out/font.ttf"; font=(font.ttf); fi
cd "$out"
python3 "$here/tools/wasi-run.py" skia-rect.wasm skia-rect.png "${font[@]}"
