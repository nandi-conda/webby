#!/usr/bin/env bash
# Builds libwebby_wasi_compat.a and installs it with netdb.h and webby_wasi_compat.h into WEBBY_WASI_SYSROOT.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); sdk=${WASI_SDK_PREFIX:?}; prefix=${WEBBY_WASI_SYSROOT:?}
mkdir -p "$prefix/include" "$prefix/lib"
"$sdk/bin/clang" --target=wasm32-wasip1 -O2 -Wall -Wextra -c "$here/webby_wasi_compat.c" -o "$prefix/lib/webby_wasi_compat.o"
rm -f "$prefix/lib/libwebby_wasi_compat.a"
"$sdk/bin/llvm-ar" rcs "$prefix/lib/libwebby_wasi_compat.a" "$prefix/lib/webby_wasi_compat.o"
rm "$prefix/lib/webby_wasi_compat.o"
cp "$here/netdb.h" "$here/webby_wasi_compat.h" "$prefix/include/"
echo "compat library in $prefix"
