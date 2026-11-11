#!/usr/bin/env bash
# Builds libwebby_wasi_compat.a and installs it with webby_wasi_compat.h and include/ (netdb.h, pwd.h, grp.h,
# spawn.h, sys/wait.h, termios.h) into WEBBY_WASI_SYSROOT.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); sdk=${WASI_SDK_PREFIX:?}; prefix=${WEBBY_WASI_SYSROOT:?}
mkdir -p "$prefix/include" "$prefix/lib"
"$sdk/bin/clang" --target=wasm32-wasip1 -O2 -Wall -Wextra -I"$here/include" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID -c "$here/webby_wasi_compat.c" -o "$prefix/lib/webby_wasi_compat.o"
rm -f "$prefix/lib/libwebby_wasi_compat.a"
"$sdk/bin/llvm-ar" rcs "$prefix/lib/libwebby_wasi_compat.a" "$prefix/lib/webby_wasi_compat.o"
rm "$prefix/lib/webby_wasi_compat.o"
cp "$here/webby_wasi_compat.h" "$prefix/include/"
cp -r "$here/include/." "$prefix/include/"
echo "compat library in $prefix"
